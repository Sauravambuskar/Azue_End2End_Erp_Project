/* ContosoERP UI. No framework on purpose - the project is about Azure, not JS.
   Every call goes through /bff/* so the browser never talks to the API directly
   and never holds an access token. */
'use strict';

const api = {
  async call(resource, { method = 'GET', body, query } = {}) {
    const qs = query ? '?' + new URLSearchParams(query) : '';
    const res = await fetch(`/bff/${resource}${qs}`, {
      method,
      headers: { 'content-type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
    });
    const text = await res.text();
    let data = {};
    try { data = text ? JSON.parse(text) : {}; } catch { data = { detail: text }; }
    if (!res.ok) throw new Error(data.detail ? JSON.stringify(data.detail) : `HTTP ${res.status}`);
    return data;
  },
};

/* Escape everything we render. The DAST stage specifically probes for stored
   XSS via product names, so this is a control, not decoration. */
const esc = (v) =>
  String(v ?? '').replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])
  );

const money = (v) =>
  Number(v ?? 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

const state = { customers: [], warehouses: [], products: [], suppliers: [] };

function toast(msg, kind = 'err') {
  const el = document.createElement('div');
  el.className = `toast ${kind}`;
  el.textContent = msg;
  document.body.appendChild(el);
  setTimeout(() => el.remove(), 5000);
}

/* ------------------------------------------------------------- navigation */
document.querySelectorAll('.tab').forEach((tab) => {
  tab.addEventListener('click', () => {
    document.querySelectorAll('.tab').forEach((t) => t.classList.remove('active'));
    document.querySelectorAll('.view').forEach((v) => v.classList.remove('active'));
    tab.classList.add('active');
    document.getElementById(tab.dataset.view).classList.add('active');
    render(tab.dataset.view);
  });
});

/* ---------------------------------------------------------------- loaders */
async function loadReferenceData() {
  const [customers, warehouses, products, suppliers] = await Promise.all([
    api.call('customers'),
    api.call('warehouses'),
    api.call('products', { query: { limit: 200 } }),
    api.call('suppliers'),
  ]);
  Object.assign(state, { customers, warehouses, products, suppliers });

  fillSelect('#so-form [name=customer_id]', customers, (c) => `${c.code} · ${c.name}`);
  fillSelect('#so-form [name=warehouse_id]', warehouses, (w) => `${w.code} · ${w.name}`);
  fillSelect('#so-form [name=product_id]', products, (p) => `${p.sku} · ${p.name}`);
  fillSelect('#po-form [name=supplier_id]', suppliers, (s) => `${s.code} · ${s.name}`);
  fillSelect('#po-form [name=warehouse_id]', warehouses, (w) => `${w.code} · ${w.name}`);
  fillSelect('#po-form [name=product_id]', products, (p) => `${p.sku} · ${p.name}`);
  fillSelect('#inv-warehouse', warehouses, (w) => `${w.code} · ${w.name}`);
}

function fillSelect(selector, items, label) {
  const el = document.querySelector(selector);
  if (!el) return;
  el.innerHTML = items.map((i) => `<option value="${i.id}">${esc(label(i))}</option>`).join('');
}

/* -------------------------------------------------------------- dashboard */
async function render(view) {
  try {
    if (view === 'dashboard') return renderDashboard();
    if (view === 'products') return renderProducts();
    if (view === 'sales') return renderSales();
    if (view === 'purchasing') return renderPurchasing();
    if (view === 'inventory') return renderInventory();
    if (view === 'finance') return renderFinance();
  } catch (err) {
    toast(`Load failed: ${err.message}`);
  }
}

async function renderDashboard() {
  const [products, customers, orders] = await Promise.all([
    api.call('products', { query: { limit: 500 } }),
    api.call('customers', { query: { limit: 500 } }),
    api.call('sales-orders', { query: { limit: 200 } }),
  ]);
  document.getElementById('kpi-products').textContent = products.length;
  document.getElementById('kpi-customers').textContent = customers.length;
  document.getElementById('kpi-orders').textContent = orders.filter(
    (o) => !['invoiced', 'cancelled'].includes(o.status)
  ).length;

  const wh = state.warehouses[0];
  if (wh) {
    const stock = await api.call('stock', { query: { warehouse_id: wh.id } });
    document.getElementById('kpi-reorder').textContent = stock.filter((s) => s.below_reorder).length;
  }

  const health = await fetch('/healthz/ready').then((r) => r.json());
  document.getElementById('health-out').textContent = JSON.stringify(health, null, 2);
}

/* --------------------------------------------------------------- products */
async function renderProducts() {
  const rows = await api.call('products', { query: { limit: 200 } });
  document.querySelector('#product-table tbody').innerHTML = rows
    .map(
      (p) => `<tr>
        <td><code>${esc(p.sku)}</code></td><td>${esc(p.name)}</td><td>${esc(p.category)}</td>
        <td class="num">${money(p.unit_price)}</td><td class="num">${money(p.standard_cost)}</td>
        <td class="num">${money(p.reorder_point)}</td></tr>`
    )
    .join('');
}

document.getElementById('product-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = new FormData(e.target);
  try {
    await api.call('products', {
      method: 'POST',
      body: {
        sku: String(f.get('sku')).toUpperCase(),
        name: f.get('name'),
        category: f.get('category') || 'general',
        unit_price: f.get('unit_price'),
        standard_cost: f.get('standard_cost') || '0',
        reorder_point: f.get('reorder_point') || '0',
      },
    });
    e.target.reset();
    toast('Product created', 'ok');
    await loadReferenceData();
    renderProducts();
  } catch (err) {
    toast(err.message);
  }
});

/* ------------------------------------------------------------------ sales */
const NEXT_STATUS = {
  draft: 'confirmed',
  confirmed: 'picked',
  picked: 'shipped',
  shipped: 'invoiced',
};

async function renderSales() {
  const rows = await api.call('sales-orders', { query: { limit: 100 } });
  const custById = new Map(state.customers.map((c) => [c.id, c]));
  document.querySelector('#so-table tbody').innerHTML = rows
    .map((o) => {
      const next = NEXT_STATUS[o.status];
      const btn = next
        ? `<button class="mini" data-so="${o.id}" data-next="${next}">→ ${next}</button>`
        : '—';
      return `<tr>
        <td><code>${esc(o.order_no)}</code></td>
        <td>${esc(custById.get(o.customer_id)?.name ?? o.customer_id)}</td>
        <td>${esc(o.order_date)}</td>
        <td><span class="pill ${esc(o.status)}">${esc(o.status)}</span></td>
        <td class="num">${money(o.total_amount)}</td>
        <td>${btn}</td></tr>`;
    })
    .join('');

  document.querySelectorAll('[data-so]').forEach((b) =>
    b.addEventListener('click', async () => {
      try {
        await api.call(`sales-orders/${b.dataset.so}/status`, {
          method: 'POST',
          body: { status: b.dataset.next },
        });
        toast(`Order moved to ${b.dataset.next}`, 'ok');
        renderSales();
      } catch (err) {
        toast(err.message);
      }
    })
  );
}

document.getElementById('so-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = new FormData(e.target);
  try {
    await api.call('sales-orders', {
      method: 'POST',
      body: {
        customer_id: Number(f.get('customer_id')),
        warehouse_id: Number(f.get('warehouse_id')),
        lines: [
          {
            product_id: Number(f.get('product_id')),
            quantity: f.get('quantity'),
            discount_pct: f.get('discount_pct') || '0',
          },
        ],
      },
    });
    toast('Sales order created', 'ok');
    renderSales();
  } catch (err) {
    toast(err.message);
  }
});

/* ------------------------------------------------------------- purchasing */
async function renderPurchasing() {
  const rows = await api.call('purchase-orders');
  const supById = new Map(state.suppliers.map((s) => [s.id, s]));
  document.querySelector('#po-table tbody').innerHTML = rows
    .map(
      (p) => `<tr>
        <td><code>${esc(p.po_no)}</code></td>
        <td>${esc(supById.get(p.supplier_id)?.name ?? p.supplier_id)}</td>
        <td>${esc(p.order_date)}</td>
        <td><span class="pill ${esc(p.status)}">${esc(p.status)}</span></td>
        <td class="num">${money(p.total_amount)}</td>
        <td>${p.status === 'draft' ? `<button class="mini" data-po="${p.id}">Receive</button>` : '—'}</td>
      </tr>`
    )
    .join('');

  document.querySelectorAll('[data-po]').forEach((b) =>
    b.addEventListener('click', async () => {
      try {
        await api.call(`purchase-orders/${b.dataset.po}/receive`, { method: 'POST' });
        toast('Goods received, stock and GL updated', 'ok');
        renderPurchasing();
      } catch (err) {
        toast(err.message);
      }
    })
  );
}

document.getElementById('po-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = new FormData(e.target);
  try {
    await api.call('purchase-orders', {
      method: 'POST',
      body: {
        supplier_id: Number(f.get('supplier_id')),
        warehouse_id: Number(f.get('warehouse_id')),
        lines: [
          {
            product_id: Number(f.get('product_id')),
            quantity: f.get('quantity'),
            unit_cost: f.get('unit_cost'),
          },
        ],
      },
    });
    toast('Purchase order created', 'ok');
    renderPurchasing();
  } catch (err) {
    toast(err.message);
  }
});

/* -------------------------------------------------------------- inventory */
async function renderInventory() {
  const whId = document.getElementById('inv-warehouse').value || state.warehouses[0]?.id;
  if (!whId) return;
  const rows = await api.call('stock', { query: { warehouse_id: whId } });
  document.querySelector('#stock-table tbody').innerHTML = rows
    .map(
      (s) => `<tr>
        <td><code>${esc(s.sku)}</code></td>
        <td class="num">${money(s.on_hand)}</td>
        <td class="num">${money(s.reorder_point)}</td>
        <td>${s.below_reorder ? '<span class="pill cancelled">reorder</span>' : '<span class="pill invoiced">ok</span>'}</td>
      </tr>`
    )
    .join('');
}
document.getElementById('inv-refresh').addEventListener('click', renderInventory);

/* ---------------------------------------------------------------- finance */
async function renderFinance() {
  const rows = await api.call('trial-balance');
  document.querySelector('#tb-table tbody').innerHTML = rows
    .map(
      (r) => `<tr><td><code>${esc(r.account_code)}</code></td>
        <td class="num">${money(r.debit_total)}</td>
        <td class="num">${money(r.credit_total)}</td>
        <td class="num">${money(r.balance)}</td></tr>`
    )
    .join('');
  const net = rows.reduce((a, r) => a + Number(r.balance), 0);
  const el = document.getElementById('tb-status');
  el.textContent = Math.abs(net) < 0.0001
    ? '✓ Ledger balanced (debits = credits)'
    : `✗ Out of balance by ${money(net)}`;
  el.className = Math.abs(net) < 0.0001 ? 'ok' : 'err';
}

/* ------------------------------------------------------------------- boot */
(async function boot() {
  try {
    const live = await fetch('/healthz/live').then((r) => r.json());
    document.getElementById('env-badge').textContent = live.env;
    document.getElementById('env-badge').classList.add(live.env);
    document.getElementById('version').textContent = `v${live.version}`;
    await loadReferenceData();
    await render('dashboard');
  } catch (err) {
    toast(`Startup failed: ${err.message}`);
    document.getElementById('env-badge').textContent = 'offline';
  }
})();
