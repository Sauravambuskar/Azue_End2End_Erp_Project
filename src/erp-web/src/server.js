/**
 * ContosoERP web tier (BFF - backend for frontend).
 *
 * Why a separate Node service exists in this project:
 *   1. It gives the DevSecOps pipeline a SECOND language to scan, so you
 *      practise npm audit / ESLint-security / Trivy on a non-Python image.
 *   2. It is the OIDC confidential client. The browser never holds a token
 *      that can call the API directly; the BFF attaches the token server-side.
 *   3. It proves pod-to-pod traffic inside AKS (web -> api over ClusterIP),
 *      which is what the NetworkPolicy in
 *      k8s/helm/erp/templates/networkpolicy.yaml guards.
 */
const express = require('express');
const helmet = require('helmet');
const morgan = require('morgan');
const rateLimit = require('express-rate-limit');
const path = require('path');
const crypto = require('crypto');

const app = express();
const PORT = process.env.PORT || 3000;
const API_BASE = process.env.ERP_API_BASE || 'http://erp-api:8000';
const ENV = process.env.ERP_ENV || 'dev';
const VERSION = process.env.ERP_BUILD_VERSION || '0.0.0-local';

app.disable('x-powered-by');
app.set('trust proxy', 1); // behind Application Gateway / ingress

// ---------------------------------------------------------------- security
app.use(
  helmet({
    contentSecurityPolicy: {
      directives: {
        defaultSrc: ["'self'"],
        scriptSrc: ["'self'"],
        styleSrc: ["'self'", "'unsafe-inline'"],
        imgSrc: ["'self'", 'data:'],
        connectSrc: ["'self'"],
        objectSrc: ["'none'"],
        frameAncestors: ["'none'"],
      },
    },
    hsts: { maxAge: 31536000, includeSubDomains: true },
    referrerPolicy: { policy: 'no-referrer' },
    // helmet defaults to SAMEORIGIN; DENY matches the API tier and the
    // App Gateway rewrite rule, so all three layers agree.
    frameguard: { action: 'deny' },
  })
);

app.use(express.json({ limit: '256kb' }));
app.use(morgan('{"ts":":date[iso]","method":":method","path":":url","status"::status,"ms"::response-time}'));

// Request correlation id, propagated to the API so one trace spans both tiers.
app.use((req, res, next) => {
  req.requestId = req.header('x-request-id') || crypto.randomUUID();
  res.setHeader('x-request-id', req.requestId);
  next();
});

app.use(
  '/bff',
  rateLimit({
    windowMs: 60_000,
    limit: 300,
    standardHeaders: 'draft-7',
    legacyHeaders: false,
  })
);

// ------------------------------------------------------------------ probes
app.get('/healthz/live', (_req, res) =>
  res.json({ status: 'ok', service: 'erp-web', env: ENV, version: VERSION })
);

app.get('/healthz/ready', async (_req, res) => {
  try {
    const r = await fetch(`${API_BASE}/healthz/ready`, { signal: AbortSignal.timeout(3000) });
    if (!r.ok) throw new Error(`api returned ${r.status}`);
    res.json({ status: 'ok', service: 'erp-web', dependencies: { api: 'ok' } });
  } catch (err) {
    res
      .status(503)
      .json({ status: 'degraded', service: 'erp-web', dependencies: { api: String(err.message) } });
  }
});

// Prometheus-style metrics so the AKS ServiceMonitor has something to scrape.
const metrics = { requests: 0, errors: 0, upstreamMs: 0 };
app.get('/metrics', (_req, res) => {
  res.type('text/plain').send(
    [
      '# TYPE erp_web_requests_total counter',
      `erp_web_requests_total ${metrics.requests}`,
      '# TYPE erp_web_upstream_errors_total counter',
      `erp_web_upstream_errors_total ${metrics.errors}`,
      '# TYPE erp_web_upstream_latency_ms_sum gauge',
      `erp_web_upstream_latency_ms_sum ${metrics.upstreamMs.toFixed(1)}`,
    ].join('\n')
  );
});

// --------------------------------------------------------------------- BFF
/**
 * Only these upstream routes are reachable from the browser. An allow-list
 * (never a wildcard proxy) is what keeps this from becoming an SSRF hole -
 * OWASP A10. ZAP's DAST scan in the pipeline tests exactly this.
 */
const ALLOWED = new Map([
  ['products', { path: '/api/v1/products', methods: ['GET', 'POST'] }],
  ['customers', { path: '/api/v1/customers', methods: ['GET', 'POST'] }],
  ['suppliers', { path: '/api/v1/suppliers', methods: ['GET', 'POST'] }],
  ['warehouses', { path: '/api/v1/warehouses', methods: ['GET', 'POST'] }],
  ['sales-orders', { path: '/api/v1/sales-orders', methods: ['GET', 'POST'] }],
  ['purchase-orders', { path: '/api/v1/purchase-orders', methods: ['GET', 'POST'] }],
  ['stock', { path: '/api/v1/inventory/stock', methods: ['GET'] }],
  ['trial-balance', { path: '/api/v1/finance/trial-balance', methods: ['GET'] }],
]);

/**
 * In Azure this exchanges the pod's workload identity for a token scoped to
 * the API's Entra app registration. Locally it returns null and the API runs
 * with ERP_AUTH_ENABLED=false.
 */
async function upstreamToken() {
  if (process.env.ERP_AUTH_ENABLED !== 'true') return null;
  const { DefaultAzureCredential } = require('@azure/identity');
  const cred = new DefaultAzureCredential();
  const scope = process.env.ERP_API_SCOPE; // e.g. api://erp-api/.default
  const token = await cred.getToken(scope);
  return token?.token ?? null;
}

app.all('/bff/:resource/:rest(*)?', async (req, res) => {
  metrics.requests += 1;
  const entry = ALLOWED.get(req.params.resource);
  if (!entry) return res.status(404).json({ detail: 'unknown resource' });
  if (!entry.methods.includes(req.method)) {
    return res.status(405).json({ detail: 'method not allowed' });
  }

  // Sub-path is restricted to digits and a few safe verbs - no path traversal.
  const rest = req.params.rest || '';
  if (rest && !/^[0-9]+(\/(status|receive))?$/.test(rest)) {
    return res.status(400).json({ detail: 'invalid sub-path' });
  }

  const qs = new URLSearchParams(req.query).toString();
  const url = `${API_BASE}${entry.path}${rest ? '/' + rest : ''}${qs ? '?' + qs : ''}`;
  const started = Date.now();

  try {
    const token = await upstreamToken();
    const upstream = await fetch(url, {
      method: req.method,
      headers: {
        'content-type': 'application/json',
        'x-request-id': req.requestId,
        ...(token ? { authorization: `Bearer ${token}` } : {}),
      },
      body: ['POST', 'PUT', 'PATCH'].includes(req.method) ? JSON.stringify(req.body) : undefined,
      signal: AbortSignal.timeout(10_000),
    });
    metrics.upstreamMs += Date.now() - started;
    const text = await upstream.text();
    res.status(upstream.status).type('application/json').send(text || '{}');
  } catch (err) {
    metrics.errors += 1;
    console.error(JSON.stringify({ level: 'error', msg: 'upstream call failed', url, err: String(err) }));
    res.status(502).json({ detail: 'upstream unavailable' });
  }
});

// ---------------------------------------------------------------- static UI
app.use(express.static(path.join(__dirname, '..', 'public'), { maxAge: '1h' }));

/**
 * SPA fallback, but NOT for API-shaped paths.
 *
 * A bare `app.get('*')` returns index.html with a 200 for literally anything,
 * including /api/v1/products - so a caller who forgets the /bff prefix gets
 * HTML and a success code instead of an error. That turns a one-line mistake
 * into a confusing debugging session, and it makes a 200 meaningless as a
 * health signal.
 *
 * Anything that looks like an API call gets a JSON 404 instead.
 */
// The trailing (\/|\.|$) also has to allow a dot, or /openapi.json slips
// through to the SPA fallback and returns HTML with a 200.
const API_SHAPED = /^\/(api|bff|v\d+|graphql|healthz|metrics|openapi)(\/|\.|$)/;

app.get('*', (req, res) => {
  if (API_SHAPED.test(req.path)) {
    return res.status(404).json({ detail: 'no such endpoint' });
  }
  res.sendFile(path.join(__dirname, '..', 'public', 'index.html'));
});

/**
 * Only start listening when this file is RUN, not when it is imported.
 *
 * Without this guard, `require('../src/server.js')` in a test starts a real
 * listener that nothing closes, the event loop never empties, and the test
 * process hangs forever instead of exiting. Found by writing the tests.
 */
function start() {
  const server = app.listen(PORT, () =>
    console.log(JSON.stringify({ msg: 'erp-web listening', port: PORT, api: API_BASE, env: ENV }))
  );

  // Graceful shutdown so AKS rolling updates drop zero requests. The 15s
  // backstop matches terminationGracePeriodSeconds in the Helm chart.
  for (const sig of ['SIGTERM', 'SIGINT']) {
    process.on(sig, () => {
      console.log(JSON.stringify({ msg: `${sig} received, draining` }));
      server.close(() => process.exit(0));
      setTimeout(() => process.exit(1), 15_000).unref();
    });
  }

  return server;
}

if (require.main === module) {
  start();
}

module.exports = app;
module.exports.start = start;
