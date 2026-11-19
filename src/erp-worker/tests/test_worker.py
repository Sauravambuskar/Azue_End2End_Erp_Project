"""Tests for the ERP background worker.

The worker's job is to detect two things and exit non-zero when it finds the
serious one, so that is what is tested:

  * the reorder scan emits parseable structured JSON (the Log Analytics KQL
    alert in guidance/11 parses these exact fields - if the shape changes,
    the alert silently stops firing)
  * the ledger integrity check returns the imbalance
  * main() returns exit code 2 on an unbalanced ledger, which is what makes
    the CronJob fail and the severity-0 alert fire

Everything is tested against a fake DB connection, so these run in CI with no
PostgreSQL, no Azure and no network.

Run:  pytest tests -q
"""
from __future__ import annotations

import json
from decimal import Decimal
from unittest import mock

import pytest

from app import main as worker


# --------------------------------------------------------------------- fakes
class FakeCursor:
    """Minimal psycopg cursor stand-in."""

    def __init__(self, rows, description=None):
        self._rows = rows
        self.description = description
        self.executed: list[str] = []

    def execute(self, sql, params=None):
        self.executed.append(sql)

    def fetchall(self):
        return self._rows

    def fetchone(self):
        return self._rows[0] if self._rows else None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeConnection:
    def __init__(self, rows_by_call):
        # rows_by_call: list of row-sets, returned in cursor() call order
        self._rows_by_call = list(rows_by_call)
        self.cursors: list[FakeCursor] = []

    def cursor(self, row_factory=None):
        rows = self._rows_by_call.pop(0) if self._rows_by_call else []
        cur = FakeCursor(rows)
        self.cursors.append(cur)
        return cur

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


# --------------------------------------------------------------------- config
def test_config_reads_environment(monkeypatch):
    monkeypatch.setenv("ERP_DB_HOST", "psql-erp-dev-cin-01.postgres.database.azure.com")
    monkeypatch.setenv("ERP_DB_NAME", "erp")
    monkeypatch.setenv("ERP_DB_USER", "id-erp-worker-dev")
    monkeypatch.setenv("ERP_DB_USE_MANAGED_IDENTITY", "true")
    monkeypatch.setenv("ERP_WORKER_JOB", "reorder")

    cfg = worker.Config()

    assert cfg.host.endswith("postgres.database.azure.com")
    assert cfg.user == "id-erp-worker-dev"
    assert cfg.use_mi is True
    assert cfg.job == "reorder"


def test_config_defaults_to_local_development(monkeypatch):
    for var in (
        "ERP_DB_HOST",
        "ERP_DB_USER",
        "ERP_DB_USE_MANAGED_IDENTITY",
        "ERP_WORKER_JOB",
    ):
        monkeypatch.delenv(var, raising=False)

    cfg = worker.Config()

    assert cfg.host == "localhost"
    assert cfg.use_mi is False, "managed identity must be OPT-IN, never the default"
    assert cfg.job == "all"


def test_password_uses_env_when_managed_identity_is_off(monkeypatch):
    monkeypatch.setenv("ERP_DB_USE_MANAGED_IDENTITY", "false")
    monkeypatch.setenv("ERP_DB_PASSWORD", "local-only")
    cfg = worker.Config()

    assert worker._password(cfg) == "local-only"


def test_password_requests_an_entra_token_when_managed_identity_is_on(monkeypatch):
    monkeypatch.setenv("ERP_DB_USE_MANAGED_IDENTITY", "true")
    cfg = worker.Config()

    fake_cred = mock.MagicMock()
    fake_cred.get_token.return_value = mock.MagicMock(token="a-jwt-not-a-password")
    fake_identity = mock.MagicMock(DefaultAzureCredential=lambda **kw: fake_cred)

    with mock.patch.dict("sys.modules", {"azure.identity": fake_identity}):
        token = worker._password(cfg)

    assert token == "a-jwt-not-a-password"
    # The scope matters: the wrong scope yields a token PostgreSQL rejects.
    fake_cred.get_token.assert_called_once_with(worker.PG_AAD_SCOPE)
    assert worker.PG_AAD_SCOPE == "https://ossrdbms-aad.database.windows.net/.default"


# ------------------------------------------------------------- reorder scan
def test_reorder_scan_emits_parseable_structured_json(caplog):
    rows = [
        {
            "id": 1,
            "sku": "BEARING-6204",
            "name": "Ball bearing",
            "warehouse_id": 1,
            "warehouse": "WH-HYD",
            "on_hand": Decimal("12"),
            "reorder_point": Decimal("200"),
        },
        {
            "id": 2,
            "sku": "SEAL-NBR-40",
            "name": "Oil seal",
            "warehouse_id": 1,
            "warehouse": "WH-HYD",
            "on_hand": Decimal("0"),
            "reorder_point": Decimal("500"),
        },
    ]
    conn = FakeConnection([rows])

    with caplog.at_level("WARNING"):
        result = worker.reorder_scan(conn)

    assert len(result) == 2

    breaches = []
    for record in caplog.records:
        try:
            payload = json.loads(record.getMessage())
        except (ValueError, TypeError):
            continue
        if payload.get("event") == "ReorderPointBreached":
            breaches.append(payload)

    assert len(breaches) == 2, "each breach must emit one parseable JSON line"

    # These exact keys are what the KQL alert parses. Renaming one silently
    # breaks the alert, which is why they are asserted explicitly.
    for payload in breaches:
        assert set(payload) == {
            "event",
            "sku",
            "warehouse",
            "on_hand",
            "reorder_point",
        }
        assert isinstance(payload["sku"], str)
        # Serialised as strings so Decimal survives the JSON round trip.
        assert isinstance(payload["on_hand"], str)

    assert {b["sku"] for b in breaches} == {"BEARING-6204", "SEAL-NBR-40"}


def test_reorder_scan_with_nothing_below_reorder_point(caplog):
    conn = FakeConnection([[]])

    with caplog.at_level("INFO"):
        result = worker.reorder_scan(conn)

    assert result == []
    assert any("0 item(s) below reorder point" in r.getMessage() for r in caplog.records)


# -------------------------------------------------------- ledger integrity
def test_gl_integrity_check_reports_balanced(caplog):
    conn = FakeConnection([[(Decimal("0"),)]])

    with caplog.at_level("INFO"):
        delta = worker.gl_integrity_check(conn)

    assert delta == Decimal("0")
    assert any("LedgerBalanced" in r.getMessage() for r in caplog.records)


def test_gl_integrity_check_reports_an_imbalance(caplog):
    conn = FakeConnection([[(Decimal("1234.5600"),)]])

    with caplog.at_level("ERROR"):
        delta = worker.gl_integrity_check(conn)

    assert delta == Decimal("1234.5600")

    events = [
        json.loads(r.getMessage())
        for r in caplog.records
        if r.getMessage().startswith("{")
    ]
    assert any(e.get("event") == "LedgerOutOfBalance" for e in events)
    # The alert reads the delta, so it must be present and stringified.
    out_of_balance = next(e for e in events if e["event"] == "LedgerOutOfBalance")
    assert out_of_balance["delta"] == "1234.5600"


def test_gl_integrity_detects_a_negative_imbalance():
    conn = FakeConnection([[(Decimal("-50"),)]])
    assert worker.gl_integrity_check(conn) == Decimal("-50")


# ---------------------------------------------------- exit codes drive alerts
@pytest.mark.parametrize(
    ("imbalance", "expected_exit"),
    [
        (Decimal("0"), 0),
        (Decimal("0.0001"), 2),
        (Decimal("-9999"), 2),
    ],
)
def test_main_exit_code_reflects_ledger_state(monkeypatch, imbalance, expected_exit):
    """A non-zero exit is what fails the CronJob and fires the sev-0 alert."""
    monkeypatch.setenv("ERP_WORKER_JOB", "gl")
    monkeypatch.setenv("ERP_DB_USE_MANAGED_IDENTITY", "false")
    monkeypatch.setenv("ERP_DB_PASSWORD", "x")

    conn = FakeConnection([[(imbalance,)]])
    monkeypatch.setattr(worker, "connect", lambda cfg: conn)

    assert worker.main() == expected_exit


def test_main_returns_1_when_the_database_is_unreachable(monkeypatch, caplog):
    monkeypatch.setenv("ERP_DB_USE_MANAGED_IDENTITY", "false")
    monkeypatch.setenv("ERP_DB_PASSWORD", "x")

    def boom(cfg):
        raise ConnectionError("could not translate host name")

    monkeypatch.setattr(worker, "connect", boom)

    with caplog.at_level("ERROR"):
        assert worker.main() == 1

    assert any("worker failed" in r.getMessage() for r in caplog.records)


def test_main_honours_the_job_selector(monkeypatch):
    """ERP_WORKER_JOB=reorder must not run the GL check."""
    monkeypatch.setenv("ERP_WORKER_JOB", "reorder")
    monkeypatch.setenv("ERP_DB_USE_MANAGED_IDENTITY", "false")
    monkeypatch.setenv("ERP_DB_PASSWORD", "x")

    conn = FakeConnection([[]])
    monkeypatch.setattr(worker, "connect", lambda cfg: conn)

    gl_called = mock.MagicMock()
    monkeypatch.setattr(worker, "gl_integrity_check", gl_called)

    assert worker.main() == 0
    gl_called.assert_not_called()


# -------------------------------------------------------- event publishing
def test_publish_events_is_a_noop_without_a_namespace(monkeypatch, caplog):
    monkeypatch.delenv("ERP_SERVICEBUS_NAMESPACE", raising=False)
    cfg = worker.Config()

    with caplog.at_level("INFO"):
        worker.publish_events(cfg, [{"type": "X"}])

    assert any("skipping" in r.getMessage() for r in caplog.records)


def test_publish_events_is_a_noop_with_no_events(monkeypatch, caplog):
    monkeypatch.setenv("ERP_SERVICEBUS_NAMESPACE", "sb-erp-dev-cin.servicebus.windows.net")
    cfg = worker.Config()

    with caplog.at_level("INFO"):
        worker.publish_events(cfg, [])

    assert any("skipping" in r.getMessage() for r in caplog.records)


# ---------------------------------------------------------------- the SQL
def test_reorder_sql_filters_to_active_products_only():
    """A deactivated product must not raise a reorder alert."""
    assert "p.is_active" in worker.REORDER_SQL
    assert "HAVING" in worker.REORDER_SQL.upper()
    # The breach condition itself: on hand below the reorder point.
    assert "< p.reorder_point" in worker.REORDER_SQL


def test_balance_sql_nets_debits_against_credits():
    assert "SUM(debit) - SUM(credit)" in worker.BALANCE_SQL
    # COALESCE so an empty ledger returns 0 rather than NULL, which would
    # otherwise crash the Decimal() conversion.
    assert "COALESCE" in worker.BALANCE_SQL.upper()
