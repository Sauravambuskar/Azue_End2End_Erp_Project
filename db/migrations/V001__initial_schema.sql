-- =====================================================================
-- ContosoERP  V001  initial schema
-- Target: Azure Database for PostgreSQL Flexible Server 16
-- Applied by: pipelines/templates/stage-migrate.yml (idempotent, forward-only)
-- =====================================================================
BEGIN;

CREATE TABLE IF NOT EXISTS schema_version (
    version      TEXT PRIMARY KEY,
    applied_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    applied_by   TEXT NOT NULL DEFAULT current_user,
    checksum     TEXT
);

DO $$ BEGIN
    CREATE TYPE order_status AS ENUM
        ('draft','confirmed','picked','shipped','invoiced','cancelled');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE movement_type AS ENUM ('receipt','issue','adjustment','transfer');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ------------------------------------------------------------ master data
CREATE TABLE IF NOT EXISTS product (
    id              SERIAL PRIMARY KEY,
    sku             VARCHAR(32)  NOT NULL UNIQUE,
    name            VARCHAR(200) NOT NULL,
    category        VARCHAR(64)  NOT NULL DEFAULT 'general',
    uom             VARCHAR(8)   NOT NULL DEFAULT 'EA',
    unit_price      NUMERIC(18,4) NOT NULL DEFAULT 0,
    standard_cost   NUMERIC(18,4) NOT NULL DEFAULT 0,
    reorder_point   NUMERIC(18,4) NOT NULL DEFAULT 0,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT ck_product_price_nonneg CHECK (unit_price >= 0)
);
CREATE INDEX IF NOT EXISTS ix_product_category ON product(category);

CREATE TABLE IF NOT EXISTS warehouse (
    id          SERIAL PRIMARY KEY,
    code        VARCHAR(16)  NOT NULL UNIQUE,
    name        VARCHAR(120) NOT NULL,
    region      VARCHAR(64)  NOT NULL DEFAULT 'centralindia',
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS customer (
    id                  SERIAL PRIMARY KEY,
    code                VARCHAR(16)  NOT NULL UNIQUE,
    name                VARCHAR(200) NOT NULL,
    email               VARCHAR(200),
    credit_limit        NUMERIC(18,4) NOT NULL DEFAULT 0,
    payment_terms_days  INTEGER      NOT NULL DEFAULT 30,
    is_active           BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS supplier (
    id              SERIAL PRIMARY KEY,
    code            VARCHAR(16)  NOT NULL UNIQUE,
    name            VARCHAR(200) NOT NULL,
    lead_time_days  INTEGER      NOT NULL DEFAULT 7,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------------ sales
CREATE TABLE IF NOT EXISTS sales_order (
    id            SERIAL PRIMARY KEY,
    order_no      VARCHAR(24) NOT NULL UNIQUE,
    customer_id   INTEGER     NOT NULL REFERENCES customer(id),
    warehouse_id  INTEGER     NOT NULL REFERENCES warehouse(id),
    order_date    DATE        NOT NULL DEFAULT CURRENT_DATE,
    status        order_status NOT NULL DEFAULT 'draft',
    currency      CHAR(3)     NOT NULL DEFAULT 'INR',
    total_amount  NUMERIC(18,4) NOT NULL DEFAULT 0,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_so_customer_date ON sales_order(customer_id, order_date);
CREATE INDEX IF NOT EXISTS ix_so_status        ON sales_order(status);

CREATE TABLE IF NOT EXISTS sales_order_line (
    id            SERIAL PRIMARY KEY,
    order_id      INTEGER NOT NULL REFERENCES sales_order(id) ON DELETE CASCADE,
    line_no       INTEGER NOT NULL,
    product_id    INTEGER NOT NULL REFERENCES product(id),
    quantity      NUMERIC(18,4) NOT NULL,
    unit_price    NUMERIC(18,4) NOT NULL,
    discount_pct  NUMERIC(5,2)  NOT NULL DEFAULT 0,
    CONSTRAINT uq_so_line         UNIQUE (order_id, line_no),
    CONSTRAINT ck_so_line_qty_pos CHECK (quantity > 0)
);
CREATE INDEX IF NOT EXISTS ix_sol_order ON sales_order_line(order_id);

-- ------------------------------------------------------------- purchasing
CREATE TABLE IF NOT EXISTS purchase_order (
    id            SERIAL PRIMARY KEY,
    po_no         VARCHAR(24) NOT NULL UNIQUE,
    supplier_id   INTEGER     NOT NULL REFERENCES supplier(id),
    warehouse_id  INTEGER     NOT NULL REFERENCES warehouse(id),
    order_date    DATE        NOT NULL DEFAULT CURRENT_DATE,
    status        order_status NOT NULL DEFAULT 'draft',
    total_amount  NUMERIC(18,4) NOT NULL DEFAULT 0,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS purchase_order_line (
    id          SERIAL PRIMARY KEY,
    order_id    INTEGER NOT NULL REFERENCES purchase_order(id) ON DELETE CASCADE,
    line_no     INTEGER NOT NULL,
    product_id  INTEGER NOT NULL REFERENCES product(id),
    quantity    NUMERIC(18,4) NOT NULL,
    unit_cost   NUMERIC(18,4) NOT NULL,
    CONSTRAINT uq_po_line UNIQUE (order_id, line_no)
);
CREATE INDEX IF NOT EXISTS ix_pol_order ON purchase_order_line(order_id);

-- -------------------------------------------------------------- inventory
CREATE TABLE IF NOT EXISTS inventory_movement (
    id             SERIAL PRIMARY KEY,
    product_id     INTEGER NOT NULL REFERENCES product(id),
    warehouse_id   INTEGER NOT NULL REFERENCES warehouse(id),
    movement_type  movement_type NOT NULL,
    quantity       NUMERIC(18,4) NOT NULL,   -- signed: + receipt, - issue
    reference      VARCHAR(64),
    moved_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_mv_product_wh ON inventory_movement(product_id, warehouse_id);
CREATE INDEX IF NOT EXISTS ix_mv_moved_at   ON inventory_movement(moved_at);

-- ---------------------------------------------------------------- finance
CREATE TABLE IF NOT EXISTS gl_entry (
    id            SERIAL PRIMARY KEY,
    batch_id      VARCHAR(36) NOT NULL,
    account_code  VARCHAR(16) NOT NULL,
    posting_date  DATE        NOT NULL DEFAULT CURRENT_DATE,
    debit         NUMERIC(18,4) NOT NULL DEFAULT 0,
    credit        NUMERIC(18,4) NOT NULL DEFAULT 0,
    description   VARCHAR(240),
    source_doc    VARCHAR(32),
    CONSTRAINT ck_gl_nonneg        CHECK (debit >= 0 AND credit >= 0),
    CONSTRAINT ck_gl_one_side_only CHECK ((debit = 0) <> (credit = 0))
);
CREATE INDEX IF NOT EXISTS ix_gl_batch   ON gl_entry(batch_id);
CREATE INDEX IF NOT EXISTS ix_gl_account ON gl_entry(account_code);
CREATE INDEX IF NOT EXISTS ix_gl_date    ON gl_entry(posting_date);

INSERT INTO schema_version(version) VALUES ('V001')
ON CONFLICT (version) DO NOTHING;

COMMIT;
