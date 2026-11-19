-- =====================================================================
-- ContosoERP  V003  reporting views used by the dashboards and the worker
-- =====================================================================
BEGIN;

CREATE OR REPLACE VIEW v_stock_on_hand AS
SELECT p.id   AS product_id,
       p.sku,
       p.name AS product_name,
       w.id   AS warehouse_id,
       w.code AS warehouse_code,
       COALESCE(SUM(m.quantity), 0) AS on_hand,
       p.reorder_point,
       (COALESCE(SUM(m.quantity), 0) < p.reorder_point) AS below_reorder
FROM product p
CROSS JOIN warehouse w
LEFT JOIN inventory_movement m
       ON m.product_id = p.id AND m.warehouse_id = w.id
WHERE p.is_active
GROUP BY p.id, p.sku, p.name, w.id, w.code, p.reorder_point;

CREATE OR REPLACE VIEW v_trial_balance AS
SELECT account_code,
       SUM(debit)  AS debit_total,
       SUM(credit) AS credit_total,
       SUM(debit) - SUM(credit) AS balance
FROM gl_entry
GROUP BY account_code
ORDER BY account_code;

CREATE OR REPLACE VIEW v_sales_by_month AS
SELECT date_trunc('month', order_date)::date AS month,
       currency,
       COUNT(*)            AS order_count,
       SUM(total_amount)   AS revenue
FROM sales_order
WHERE status NOT IN ('draft','cancelled')
GROUP BY 1, 2
ORDER BY 1 DESC;

CREATE OR REPLACE VIEW v_customer_exposure AS
SELECT c.id, c.code, c.name, c.credit_limit,
       COALESCE(SUM(so.total_amount), 0) AS open_value,
       c.credit_limit - COALESCE(SUM(so.total_amount), 0) AS headroom
FROM customer c
LEFT JOIN sales_order so
       ON so.customer_id = c.id AND so.status IN ('confirmed','picked','shipped')
GROUP BY c.id, c.code, c.name, c.credit_limit;

GRANT SELECT ON v_stock_on_hand, v_trial_balance, v_sales_by_month, v_customer_exposure
  TO erp_app, erp_readonly;

INSERT INTO schema_version(version) VALUES ('V003') ON CONFLICT DO NOTHING;
COMMIT;
