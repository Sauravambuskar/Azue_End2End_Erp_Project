"""Pydantic request/response contracts.

Validation here is a security control, not just ergonomics: it is the first
layer of the OWASP "A03 Injection" defence and keeps the DAST scanner quiet.
"""
from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator

from app.models.erp import MovementType, OrderStatus

SKU_PATTERN = r"^[A-Z0-9][A-Z0-9\-]{2,31}$"
CODE_PATTERN = r"^[A-Z0-9\-]{2,16}$"


class ORMModel(BaseModel):
    model_config = ConfigDict(from_attributes=True)


# ------------------------------------------------------------------- product
class ProductIn(BaseModel):
    sku: str = Field(pattern=SKU_PATTERN)
    name: str = Field(min_length=1, max_length=200)
    category: str = Field(default="general", max_length=64)
    uom: str = Field(default="EA", max_length=8)
    unit_price: Decimal = Field(ge=0, le=Decimal("99999999"))
    standard_cost: Decimal = Field(default=Decimal(0), ge=0)
    reorder_point: Decimal = Field(default=Decimal(0), ge=0)


class ProductOut(ORMModel):
    id: int
    sku: str
    name: str
    category: str
    uom: str
    unit_price: Decimal
    standard_cost: Decimal
    reorder_point: Decimal
    is_active: bool
    created_at: datetime


# ------------------------------------------------------------------ customer
class CustomerIn(BaseModel):
    code: str = Field(pattern=CODE_PATTERN)
    name: str = Field(min_length=1, max_length=200)
    email: EmailStr | None = None
    credit_limit: Decimal = Field(default=Decimal(0), ge=0)
    payment_terms_days: int = Field(default=30, ge=0, le=180)


class CustomerOut(ORMModel):
    id: int
    code: str
    name: str
    email: str | None
    credit_limit: Decimal
    payment_terms_days: int
    is_active: bool


# ------------------------------------------------------------------ supplier
class SupplierIn(BaseModel):
    code: str = Field(pattern=CODE_PATTERN)
    name: str = Field(min_length=1, max_length=200)
    lead_time_days: int = Field(default=7, ge=0, le=365)


class SupplierOut(ORMModel):
    id: int
    code: str
    name: str
    lead_time_days: int


# ----------------------------------------------------------------- warehouse
class WarehouseIn(BaseModel):
    code: str = Field(pattern=CODE_PATTERN)
    name: str = Field(min_length=1, max_length=120)
    region: str = Field(default="centralindia", max_length=64)


class WarehouseOut(ORMModel):
    id: int
    code: str
    name: str
    region: str


# --------------------------------------------------------------- sales order
class SalesOrderLineIn(BaseModel):
    product_id: int = Field(gt=0)
    quantity: Decimal = Field(gt=0, le=Decimal("1000000"))
    unit_price: Decimal | None = Field(default=None, ge=0)
    discount_pct: Decimal = Field(default=Decimal(0), ge=0, le=100)


class SalesOrderIn(BaseModel):
    customer_id: int = Field(gt=0)
    warehouse_id: int = Field(gt=0)
    order_date: date | None = None
    currency: str = Field(default="INR", pattern=r"^[A-Z]{3}$")
    lines: list[SalesOrderLineIn] = Field(min_length=1, max_length=200)

    @field_validator("lines")
    @classmethod
    def _unique_products(cls, v: list[SalesOrderLineIn]) -> list[SalesOrderLineIn]:
        ids = [line.product_id for line in v]
        if len(ids) != len(set(ids)):
            raise ValueError("duplicate product in order lines")
        return v


class SalesOrderLineOut(ORMModel):
    id: int
    line_no: int
    product_id: int
    quantity: Decimal
    unit_price: Decimal
    discount_pct: Decimal


class SalesOrderOut(ORMModel):
    id: int
    order_no: str
    customer_id: int
    warehouse_id: int
    order_date: date
    status: OrderStatus
    currency: str
    total_amount: Decimal
    lines: list[SalesOrderLineOut]


class StatusChange(BaseModel):
    status: OrderStatus


# ------------------------------------------------------------ purchase order
class PurchaseOrderLineIn(BaseModel):
    product_id: int = Field(gt=0)
    quantity: Decimal = Field(gt=0)
    unit_cost: Decimal = Field(ge=0)


class PurchaseOrderIn(BaseModel):
    supplier_id: int = Field(gt=0)
    warehouse_id: int = Field(gt=0)
    lines: list[PurchaseOrderLineIn] = Field(min_length=1, max_length=200)


class PurchaseOrderOut(ORMModel):
    id: int
    po_no: str
    supplier_id: int
    warehouse_id: int
    order_date: date
    status: OrderStatus
    total_amount: Decimal


# ----------------------------------------------------------------- inventory
class MovementIn(BaseModel):
    product_id: int = Field(gt=0)
    warehouse_id: int = Field(gt=0)
    movement_type: MovementType
    quantity: Decimal
    reference: str | None = Field(default=None, max_length=64)


class StockLevel(BaseModel):
    product_id: int
    sku: str
    warehouse_id: int
    on_hand: Decimal
    reorder_point: Decimal
    below_reorder: bool


# ------------------------------------------------------------------- finance
class GLEntryOut(ORMModel):
    id: int
    batch_id: str
    account_code: str
    posting_date: date
    debit: Decimal
    credit: Decimal
    description: str | None
    source_doc: str | None


class TrialBalanceRow(BaseModel):
    account_code: str
    debit_total: Decimal
    credit_total: Decimal
    balance: Decimal


# -------------------------------------------------------------------- health
class HealthOut(BaseModel):
    status: str
    service: str
    env: str
    version: str
    database: str
    checks: dict[str, str] = {}
