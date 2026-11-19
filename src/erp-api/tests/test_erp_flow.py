"""End-to-end business flow on an in-memory SQLite database.

Runs in the CI unit-test stage with zero Azure dependencies - that is the whole
point of keeping business logic in app/services.py.
"""
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.db import Base, get_db
from app.main import app

engine = create_engine(
    "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool
)
TestingSession = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


def _override_db():
    db = TestingSession()
    try:
        yield db
    finally:
        db.close()


app.dependency_overrides[get_db] = _override_db


@pytest.fixture(scope="module", autouse=True)
def _schema():
    Base.metadata.create_all(engine)
    yield
    Base.metadata.drop_all(engine)


@pytest.fixture(scope="module")
def client():
    with TestClient(app) as c:
        yield c


@pytest.fixture(scope="module")
def seeded(client):
    wh = client.post(
        "/api/v1/warehouses", json={"code": "WH-HYD", "name": "Hyderabad DC"}
    ).json()
    cust = client.post(
        "/api/v1/customers",
        json={"code": "CUST-001", "name": "Acme Industries", "credit_limit": "500000"},
    ).json()
    sup = client.post(
        "/api/v1/suppliers", json={"code": "SUP-001", "name": "Steelworks Ltd"}
    ).json()
    prod = client.post(
        "/api/v1/products",
        json={
            "sku": "BEARING-6204",
            "name": "Ball bearing 6204",
            "category": "components",
            "unit_price": "250.00",
            "standard_cost": "180.00",
            "reorder_point": "20",
        },
    ).json()
    return {"wh": wh, "cust": cust, "sup": sup, "prod": prod}


def test_health_live(client):
    r = client.get("/healthz/live")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


def test_security_headers_present(client):
    r = client.get("/healthz/live")
    assert r.headers["X-Content-Type-Options"] == "nosniff"
    assert r.headers["X-Frame-Options"] == "DENY"
    assert "X-Request-Id" in r.headers


def test_product_sku_validation(client):
    r = client.post(
        "/api/v1/products",
        json={"sku": "bad sku!", "name": "x", "unit_price": "1"},
    )
    assert r.status_code == 422


def test_duplicate_sku_conflicts(client, seeded):
    r = client.post(
        "/api/v1/products",
        json={"sku": "BEARING-6204", "name": "dupe", "unit_price": "1"},
    )
    assert r.status_code == 409


def test_purchase_receive_increases_stock(client, seeded):
    po = client.post(
        "/api/v1/purchase-orders",
        json={
            "supplier_id": seeded["sup"]["id"],
            "warehouse_id": seeded["wh"]["id"],
            "lines": [
                {"product_id": seeded["prod"]["id"], "quantity": "100", "unit_cost": "180"}
            ],
        },
    )
    assert po.status_code == 201
    assert Decimal(po.json()["total_amount"]) == Decimal("18000")

    recv = client.post(f"/api/v1/purchase-orders/{po.json()['id']}/receive")
    assert recv.status_code == 200

    stock = client.get(
        f"/api/v1/inventory/stock/{seeded['prod']['id']}",
        params={"warehouse_id": seeded["wh"]["id"]},
    )
    assert Decimal(stock.json()["on_hand"]) == Decimal("100")


def test_sales_order_full_lifecycle(client, seeded):
    so = client.post(
        "/api/v1/sales-orders",
        json={
            "customer_id": seeded["cust"]["id"],
            "warehouse_id": seeded["wh"]["id"],
            "lines": [
                {
                    "product_id": seeded["prod"]["id"],
                    "quantity": "10",
                    "unit_price": "250",
                    "discount_pct": "10",
                }
            ],
        },
    )
    assert so.status_code == 201
    body = so.json()
    # 10 * 250 = 2500, less 10% = 2250
    assert Decimal(body["total_amount"]) == Decimal("2250")
    oid = body["id"]

    for target in ("confirmed", "picked", "shipped", "invoiced"):
        r = client.post(f"/api/v1/sales-orders/{oid}/status", json={"status": target})
        assert r.status_code == 200, r.text
        assert r.json()["status"] == target


def test_illegal_status_transition_rejected(client, seeded):
    so = client.post(
        "/api/v1/sales-orders",
        json={
            "customer_id": seeded["cust"]["id"],
            "warehouse_id": seeded["wh"]["id"],
            "lines": [{"product_id": seeded["prod"]["id"], "quantity": "1"}],
        },
    ).json()
    r = client.post(f"/api/v1/sales-orders/{so['id']}/status", json={"status": "invoiced"})
    assert r.status_code == 409


def test_oversell_is_blocked(client, seeded):
    so = client.post(
        "/api/v1/sales-orders",
        json={
            "customer_id": seeded["cust"]["id"],
            "warehouse_id": seeded["wh"]["id"],
            "lines": [{"product_id": seeded["prod"]["id"], "quantity": "999999"}],
        },
    ).json()
    client.post(f"/api/v1/sales-orders/{so['id']}/status", json={"status": "confirmed"})
    client.post(f"/api/v1/sales-orders/{so['id']}/status", json={"status": "picked"})
    r = client.post(f"/api/v1/sales-orders/{so['id']}/status", json={"status": "shipped"})
    assert r.status_code == 409
    assert "insufficient stock" in r.json()["detail"]


def test_duplicate_product_lines_rejected(client, seeded):
    r = client.post(
        "/api/v1/sales-orders",
        json={
            "customer_id": seeded["cust"]["id"],
            "warehouse_id": seeded["wh"]["id"],
            "lines": [
                {"product_id": seeded["prod"]["id"], "quantity": "1"},
                {"product_id": seeded["prod"]["id"], "quantity": "2"},
            ],
        },
    )
    assert r.status_code == 422


def test_trial_balance_is_balanced(client, seeded):
    rows = client.get("/api/v1/finance/trial-balance").json()
    assert rows, "expected GL postings from receipt + invoice"
    total = sum(Decimal(r["balance"]) for r in rows)
    assert total == Decimal(0), f"ledger out of balance by {total}"
