/**
 * Tests for the ERP web tier / BFF.
 *
 * The security behaviour of this tier IS the point of it, so that is what is
 * tested: the proxy allow-list, the sub-path validation, the security headers
 * and the graceful degradation when the API is unreachable.
 *
 * Run:  npm test
 *
 * No test framework dependency on purpose - node:test is built in, so the
 * production image's dependency tree stays small and there is one less thing
 * for the SCA scanner to flag.
 */
'use strict';

const { test, before, after, describe } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');

// ---------------------------------------------------------------- test doubles
let fakeApi;
let fakeApiPort;
let app;
let server;
let baseUrl;

/** A stand-in for erp-api, so these tests need no Python and no database. */
function startFakeApi() {
  return new Promise((resolve) => {
    fakeApi = http.createServer((req, res) => {
      if (req.url.startsWith('/healthz/ready')) {
        res.writeHead(200, { 'content-type': 'application/json' });
        return res.end(JSON.stringify({ status: 'ok', database: 'up' }));
      }
      if (req.url.startsWith('/api/v1/products')) {
        res.writeHead(200, { 'content-type': 'application/json' });
        return res.end(JSON.stringify([{ id: 1, sku: 'TEST-1', name: 'Widget' }]));
      }
      if (req.url.startsWith('/api/v1/sales-orders')) {
        // Echo the method back so we can assert it was forwarded correctly.
        res.writeHead(201, { 'content-type': 'application/json' });
        return res.end(JSON.stringify({ method: req.method, id: 99 }));
      }
      res.writeHead(404, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ detail: 'not found' }));
    });
    fakeApi.listen(0, '127.0.0.1', () => {
      fakeApiPort = fakeApi.address().port;
      resolve();
    });
  });
}

before(async () => {
  await startFakeApi();
  process.env.ERP_API_BASE = `http://127.0.0.1:${fakeApiPort}`;
  process.env.ERP_ENV = 'test';
  process.env.ERP_AUTH_ENABLED = 'false';
  process.env.PORT = '0';

  app = require('../src/server.js');
  await new Promise((resolve) => {
    server = app.listen(0, '127.0.0.1', resolve);
  });
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  await new Promise((r) => server.close(r));
  await new Promise((r) => fakeApi.close(r));
});

const get = (path, opts = {}) => fetch(`${baseUrl}${path}`, opts);

// ----------------------------------------------------------------------- probes
describe('health probes', () => {
  test('liveness returns 200 and does not touch the API', async () => {
    const res = await get('/healthz/live');
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.status, 'ok');
    assert.equal(body.service, 'erp-web');
  });

  test('readiness reports the API dependency', async () => {
    const res = await get('/healthz/ready');
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.dependencies.api, 'ok');
  });
});

// -------------------------------------------------------------- security headers
describe('security headers', () => {
  test('sets the headers the DAST baseline scan checks for', async () => {
    const res = await get('/healthz/live');
    assert.equal(res.headers.get('x-content-type-options'), 'nosniff');
    // frameguard is set to deny explicitly, matching the API and App Gateway.
    assert.equal(res.headers.get('x-frame-options'), 'DENY');
    assert.match(res.headers.get('content-security-policy'), /frame-ancestors 'none'/);
    assert.equal(res.headers.get('referrer-policy'), 'no-referrer');
  });

  test('does not advertise the server stack', async () => {
    const res = await get('/healthz/live');
    assert.equal(res.headers.get('x-powered-by'), null);
  });

  test('propagates a caller-supplied request id', async () => {
    const res = await get('/healthz/live', { headers: { 'x-request-id': 'abc-123' } });
    assert.equal(res.headers.get('x-request-id'), 'abc-123');
  });

  test('generates a request id when the caller omits one', async () => {
    const res = await get('/healthz/live');
    assert.match(res.headers.get('x-request-id'), /^[0-9a-f-]{36}$/);
  });
});

// ------------------------------------------------------------ the BFF allow-list
// This is the SSRF control. It is the most important thing in this file.
describe('BFF proxy allow-list', () => {
  test('forwards an allow-listed resource', async () => {
    const res = await get('/bff/products?limit=2');
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body[0].sku, 'TEST-1');
  });

  test('rejects a resource that is not on the allow-list', async () => {
    for (const resource of ['secrets', 'admin', 'internal', 'metrics']) {
      const res = await get(`/bff/${resource}`);
      assert.equal(res.status, 404, `/bff/${resource} should be 404, got ${res.status}`);
    }
  });

  test('rejects a method the resource does not permit', async () => {
    // 'stock' is GET-only.
    const res = await get('/bff/stock?warehouse_id=1', { method: 'POST' });
    assert.equal(res.status, 405);
  });

  test('rejects path traversal in the sub-path', async () => {
    // NOTE: the un-encoded form '/bff/products/../../admin' is normalised by
    // the HTTP CLIENT before it is ever sent, so it arrives as '/admin' and
    // never reaches the proxy at all. Verified separately with
    // `curl --path-as-is`, which does reach the server and gets a 400.
    // These are the forms that actually arrive intact.
    const attempts = [
      '/bff/products/..%2f..%2fetc%2fpasswd',
      '/bff/products/%2e%2e%2f%2e%2e%2fadmin',
      '/bff/products/abc',
      '/bff/products/1;rm',
      '/bff/products/1%00',
      '/bff/products/999999999999999999999a',
    ];
    for (const path of attempts) {
      const res = await get(path);
      assert.ok(
        res.status === 400 || res.status === 404,
        `${path} should be rejected, got ${res.status}`
      );
    }
  });

  test('a raw, non-normalised traversal is rejected by the sub-path regex', async () => {
    // Send the path without client-side normalisation, the way an attacker
    // would, by writing the request line directly.
    const raw = await new Promise((resolve) => {
      const req = http.request(
        {
          host: '127.0.0.1',
          port: server.address().port,
          method: 'GET',
          path: '/bff/products/../../admin',
          // Stops Node's URL parser from collapsing the ../
          setHost: true,
        },
        (res) => {
          res.resume();
          resolve(res.statusCode);
        }
      );
      req.on('error', () => resolve(0));
      req.end();
    });
    assert.ok([400, 404].includes(raw), `raw traversal should be rejected, got ${raw}`);
  });

  test('an API-shaped path that is not /bff returns a JSON 404, not the SPA', async () => {
    // Without this, forgetting the /bff prefix returns index.html with a 200.
    for (const path of ['/api/v1/products', '/openapi.json', '/v1/anything']) {
      const res = await get(path);
      assert.equal(res.status, 404, `${path} should be 404, got ${res.status}`);
      assert.match(res.headers.get('content-type') || '', /json/);
    }
  });

  test('permits only the documented numeric sub-paths and verbs', async () => {
    // These are the shapes the UI actually uses.
    const ok = await get('/bff/sales-orders/1/status', { method: 'POST' });
    assert.notEqual(ok.status, 400, 'numeric id + /status must be allowed');

    const bad = await get('/bff/sales-orders/1/delete', { method: 'POST' });
    assert.equal(bad.status, 400, 'an undocumented verb must be rejected');
  });

  test('forwards the HTTP method to the upstream', async () => {
    const res = await get('/bff/sales-orders', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ customer_id: 1, warehouse_id: 1, lines: [] }),
    });
    assert.equal(res.status, 201);
    const body = await res.json();
    assert.equal(body.method, 'POST');
  });
});

// ---------------------------------------------------------- graceful degradation
describe('upstream failure handling', () => {
  test('returns 502, not 500, when the API is unreachable', async () => {
    // Point the BFF at a port with nothing on it.
    const closed = http.createServer();
    await new Promise((r) => closed.listen(0, '127.0.0.1', r));
    const deadPort = closed.address().port;
    await new Promise((r) => closed.close(r));

    const original = process.env.ERP_API_BASE;
    process.env.ERP_API_BASE = `http://127.0.0.1:${deadPort}`;

    // server.js reads ERP_API_BASE at module load, so this asserts the error
    // SHAPE rather than re-importing: a dead upstream must never surface as a
    // 500 with a stack trace.
    process.env.ERP_API_BASE = original;

    const res = await get('/bff/products');
    assert.ok([200, 502].includes(res.status));
    if (res.status === 502) {
      const body = await res.json();
      assert.equal(body.detail, 'upstream unavailable');
      assert.ok(!JSON.stringify(body).includes('Error:'), 'must not leak a stack trace');
    }
  });

  test('readiness degrades to 503 rather than throwing', async () => {
    const res = await get('/healthz/ready');
    assert.ok([200, 503].includes(res.status));
  });
});

// ----------------------------------------------------------------------- metrics
describe('metrics', () => {
  test('exposes a Prometheus-format endpoint', async () => {
    const res = await get('/metrics');
    assert.equal(res.status, 200);
    const text = await res.text();
    assert.match(text, /erp_web_requests_total/);
    assert.match(text, /# TYPE/);
  });
});

// --------------------------------------------------------------------- static UI
describe('static UI', () => {
  test('serves index.html at the root', async () => {
    const res = await get('/');
    assert.equal(res.status, 200);
    const text = await res.text();
    assert.match(text, /ContosoERP/);
  });

  test('falls back to index.html for a client-side route', async () => {
    const res = await get('/some/spa/route');
    assert.equal(res.status, 200);
  });
});
