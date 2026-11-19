"""ContosoERP background worker.

Responsibilities
----------------
1. Reorder alerts     - scan stock levels, raise an alert when below reorder point.
2. Nightly GL close   - verify the trial balance nets to zero, emit a metric.
3. Event publishing   - push domain events to Azure Service Bus (optional).

Why this exists in the project
------------------------------
It gives you a second, *different* workload shape to deploy on AKS:
  * the API is a Deployment behind a Service + Ingress,
  * this worker is a CronJob (and a Deployment for the queue consumer),
so you practise KEDA scaling, CronJob RBAC, and separate managed identities.
"""
from __future__ import annotations

import json
import logging
import os
import sys
import time
from dataclasses import dataclass, field
from decimal import Decimal

import psycopg

logging.basicConfig(
    level=os.getenv("ERP_LOG_LEVEL", "INFO"),
    format='{"ts":"%(asctime)s","level":"%(levelname)s","msg":"%(message)s"}',
)
log = logging.getLogger("erp.worker")

PG_AAD_SCOPE = "https://ossrdbms-aad.database.windows.net/.default"


@dataclass
class Config:
    host: str = field(default_factory=lambda: os.getenv("ERP_DB_HOST", "localhost"))
    port: int = field(default_factory=lambda: int(os.getenv("ERP_DB_PORT", "5432")))
    dbname: str = field(default_factory=lambda: os.getenv("ERP_DB_NAME", "erp"))
    user: str = field(default_factory=lambda: os.getenv("ERP_DB_USER", "erpadmin"))
    password: str | None = field(default_factory=lambda: os.getenv("ERP_DB_PASSWORD"))
    use_mi: bool = field(
        default_factory=lambda: os.getenv("ERP_DB_USE_MANAGED_IDENTITY", "false").lower()
        == "true"
    )
    sb_namespace: str | None = field(
        default_factory=lambda: os.getenv("ERP_SERVICEBUS_NAMESPACE")
    )
    sb_queue: str = field(
        default_factory=lambda: os.getenv("ERP_SERVICEBUS_QUEUE", "erp-events")
    )
    job: str = field(default_factory=lambda: os.getenv("ERP_WORKER_JOB", "all"))


def _password(cfg: Config) -> str:
    if not cfg.use_mi:
        return cfg.password or ""
    from azure.identity import DefaultAzureCredential

    cred = DefaultAzureCredential(exclude_interactive_browser_credential=True)
    log.info("acquiring AAD token for PostgreSQL via workload identity")
    return cred.get_token(PG_AAD_SCOPE).token


def connect(cfg: Config) -> psycopg.Connection:
    return psycopg.connect(
        host=cfg.host,
        port=cfg.port,
        dbname=cfg.dbname,
        user=cfg.user,
        password=_password(cfg),
        sslmode="require" if cfg.use_mi else os.getenv("ERP_DB_SSLMODE", "prefer"),
        connect_timeout=10,
    )


# ------------------------------------------------------------------- job 1
REORDER_SQL = """
SELECT p.id, p.sku, p.name, w.id AS warehouse_id, w.code AS warehouse,
       COALESCE(SUM(m.quantity), 0) AS on_hand, p.reorder_point
FROM product p
CROSS JOIN warehouse w
LEFT JOIN inventory_movement m
       ON m.product_id = p.id AND m.warehouse_id = w.id
WHERE p.is_active
GROUP BY p.id, p.sku, p.name, w.id, w.code, p.reorder_point
HAVING COALESCE(SUM(m.quantity), 0) < p.reorder_point
ORDER BY p.sku
"""


def reorder_scan(conn: psycopg.Connection) -> list[dict]:
    with conn.cursor(row_factory=psycopg.rows.dict_row) as cur:
        cur.execute(REORDER_SQL)
        rows = cur.fetchall()
    for r in rows:
        # These structured lines are what the Log Analytics KQL alert queries.
        log.warning(
            json.dumps(
                {
                    "event": "ReorderPointBreached",
                    "sku": r["sku"],
                    "warehouse": r["warehouse"],
                    "on_hand": str(r["on_hand"]),
                    "reorder_point": str(r["reorder_point"]),
                }
            )
        )
    log.info("reorder scan complete: %d item(s) below reorder point", len(rows))
    return rows


# ------------------------------------------------------------------- job 2
BALANCE_SQL = "SELECT COALESCE(SUM(debit) - SUM(credit), 0) FROM gl_entry"


def gl_integrity_check(conn: psycopg.Connection) -> Decimal:
    with conn.cursor() as cur:
        cur.execute(BALANCE_SQL)
        (delta,) = cur.fetchone()
    delta = Decimal(delta)
    if delta != 0:
        log.error(
            json.dumps({"event": "LedgerOutOfBalance", "delta": str(delta)})
        )
    else:
        log.info(json.dumps({"event": "LedgerBalanced", "delta": "0"}))
    return delta


# ------------------------------------------------------------------- job 3
def publish_events(cfg: Config, events: list[dict]) -> None:
    if not cfg.sb_namespace or not events:
        log.info("service bus not configured or nothing to publish - skipping")
        return
    from azure.identity import DefaultAzureCredential
    from azure.servicebus import ServiceBusClient, ServiceBusMessage

    cred = DefaultAzureCredential(exclude_interactive_browser_credential=True)
    with (
        ServiceBusClient(cfg.sb_namespace, cred) as client,
        client.get_queue_sender(cfg.sb_queue) as sender,
    ):
        sender.send_messages(
            [ServiceBusMessage(json.dumps(e, default=str)) for e in events]
        )
    log.info("published %d event(s) to %s", len(events), cfg.sb_queue)


# --------------------------------------------------------------------- main
def main() -> int:
    cfg = Config()
    started = time.perf_counter()
    log.info("worker starting job=%s target=%s/%s", cfg.job, cfg.host, cfg.dbname)
    exit_code = 0
    try:
        with connect(cfg) as conn:
            breaches: list[dict] = []
            if cfg.job in ("all", "reorder"):
                breaches = reorder_scan(conn)
            if cfg.job in ("all", "gl") and gl_integrity_check(conn) != 0:
                # Non-zero exit -> the CronJob is marked Failed -> alert fires.
                exit_code = 2
            if cfg.job in ("all", "events"):
                publish_events(
                    cfg,
                    [{"type": "ReorderPointBreached", **b} for b in breaches],
                )
    except Exception:
        log.exception("worker failed")
        return 1
    finally:
        log.info("worker finished in %.2fs", time.perf_counter() - started)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
