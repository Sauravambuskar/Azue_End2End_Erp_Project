"""ContosoERP domain model.

Modules represented:
  MasterData  -> Product, Customer, Supplier, Warehouse
  Sales       -> SalesOrder / SalesOrderLine
  Purchasing  -> PurchaseOrder / PurchaseOrderLine
  Inventory   -> InventoryMovement
  Finance     -> GLEntry  (double-entry general ledger)
"""
from __future__ import annotations

import enum
from datetime import date, datetime
from decimal import Decimal

from sqlalchemy import (
    CheckConstraint,
    Date,
    DateTime,
    Enum,
    ForeignKey,
    Index,
    Numeric,
    String,
    UniqueConstraint,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.db import Base

MONEY = Numeric(18, 4)
QTY = Numeric(18, 4)


# StrEnum (3.11+) rather than (str, Enum): same behaviour, no mixin pitfalls.
class OrderStatus(enum.StrEnum):
    draft = "draft"
    confirmed = "confirmed"
    picked = "picked"
    shipped = "shipped"
    invoiced = "invoiced"
    cancelled = "cancelled"


class MovementType(enum.StrEnum):
    receipt = "receipt"
    issue = "issue"
    adjustment = "adjustment"
    transfer = "transfer"


class TimestampMixin:
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )


# --------------------------------------------------------------- master data
class Product(TimestampMixin, Base):
    __tablename__ = "product"

    id: Mapped[int] = mapped_column(primary_key=True)
    sku: Mapped[str] = mapped_column(String(32), unique=True, index=True)
    name: Mapped[str] = mapped_column(String(200))
    category: Mapped[str] = mapped_column(String(64), default="general", index=True)
    uom: Mapped[str] = mapped_column(String(8), default="EA")
    unit_price: Mapped[Decimal] = mapped_column(MONEY, default=0)
    standard_cost: Mapped[Decimal] = mapped_column(MONEY, default=0)
    reorder_point: Mapped[Decimal] = mapped_column(QTY, default=0)
    is_active: Mapped[bool] = mapped_column(default=True)

    __table_args__ = (CheckConstraint("unit_price >= 0", name="ck_product_price_nonneg"),)


class Warehouse(TimestampMixin, Base):
    __tablename__ = "warehouse"

    id: Mapped[int] = mapped_column(primary_key=True)
    code: Mapped[str] = mapped_column(String(16), unique=True)
    name: Mapped[str] = mapped_column(String(120))
    region: Mapped[str] = mapped_column(String(64), default="centralindia")


class Customer(TimestampMixin, Base):
    __tablename__ = "customer"

    id: Mapped[int] = mapped_column(primary_key=True)
    code: Mapped[str] = mapped_column(String(16), unique=True, index=True)
    name: Mapped[str] = mapped_column(String(200))
    email: Mapped[str | None] = mapped_column(String(200))
    credit_limit: Mapped[Decimal] = mapped_column(MONEY, default=0)
    payment_terms_days: Mapped[int] = mapped_column(default=30)
    is_active: Mapped[bool] = mapped_column(default=True)

    orders: Mapped[list[SalesOrder]] = relationship(back_populates="customer")


class Supplier(TimestampMixin, Base):
    __tablename__ = "supplier"

    id: Mapped[int] = mapped_column(primary_key=True)
    code: Mapped[str] = mapped_column(String(16), unique=True, index=True)
    name: Mapped[str] = mapped_column(String(200))
    lead_time_days: Mapped[int] = mapped_column(default=7)


# --------------------------------------------------------------------- sales
class SalesOrder(TimestampMixin, Base):
    __tablename__ = "sales_order"

    id: Mapped[int] = mapped_column(primary_key=True)
    order_no: Mapped[str] = mapped_column(String(24), unique=True, index=True)
    customer_id: Mapped[int] = mapped_column(ForeignKey("customer.id"), index=True)
    warehouse_id: Mapped[int] = mapped_column(ForeignKey("warehouse.id"))
    order_date: Mapped[date] = mapped_column(Date, default=date.today)
    status: Mapped[OrderStatus] = mapped_column(
        Enum(OrderStatus, name="order_status"), default=OrderStatus.draft, index=True
    )
    currency: Mapped[str] = mapped_column(String(3), default="INR")
    total_amount: Mapped[Decimal] = mapped_column(MONEY, default=0)

    customer: Mapped[Customer] = relationship(back_populates="orders")
    lines: Mapped[list[SalesOrderLine]] = relationship(
        back_populates="order", cascade="all, delete-orphan"
    )

    __table_args__ = (Index("ix_so_customer_date", "customer_id", "order_date"),)


class SalesOrderLine(Base):
    __tablename__ = "sales_order_line"

    id: Mapped[int] = mapped_column(primary_key=True)
    order_id: Mapped[int] = mapped_column(
        ForeignKey("sales_order.id", ondelete="CASCADE"), index=True
    )
    line_no: Mapped[int] = mapped_column()
    product_id: Mapped[int] = mapped_column(ForeignKey("product.id"))
    quantity: Mapped[Decimal] = mapped_column(QTY)
    unit_price: Mapped[Decimal] = mapped_column(MONEY)
    discount_pct: Mapped[Decimal] = mapped_column(Numeric(5, 2), default=0)

    order: Mapped[SalesOrder] = relationship(back_populates="lines")
    product: Mapped[Product] = relationship()

    __table_args__ = (
        UniqueConstraint("order_id", "line_no", name="uq_so_line"),
        CheckConstraint("quantity > 0", name="ck_so_line_qty_pos"),
    )

    @property
    def line_total(self) -> Decimal:
        disc = self.discount_pct or Decimal(0)
        return (self.quantity * self.unit_price) * (1 - disc / 100)


# ---------------------------------------------------------------- purchasing
class PurchaseOrder(TimestampMixin, Base):
    __tablename__ = "purchase_order"

    id: Mapped[int] = mapped_column(primary_key=True)
    po_no: Mapped[str] = mapped_column(String(24), unique=True, index=True)
    supplier_id: Mapped[int] = mapped_column(ForeignKey("supplier.id"), index=True)
    warehouse_id: Mapped[int] = mapped_column(ForeignKey("warehouse.id"))
    order_date: Mapped[date] = mapped_column(Date, default=date.today)
    status: Mapped[OrderStatus] = mapped_column(
        Enum(OrderStatus, name="order_status", create_type=False),
        default=OrderStatus.draft,
    )
    total_amount: Mapped[Decimal] = mapped_column(MONEY, default=0)

    lines: Mapped[list[PurchaseOrderLine]] = relationship(
        back_populates="order", cascade="all, delete-orphan"
    )


class PurchaseOrderLine(Base):
    __tablename__ = "purchase_order_line"

    id: Mapped[int] = mapped_column(primary_key=True)
    order_id: Mapped[int] = mapped_column(
        ForeignKey("purchase_order.id", ondelete="CASCADE"), index=True
    )
    line_no: Mapped[int] = mapped_column()
    product_id: Mapped[int] = mapped_column(ForeignKey("product.id"))
    quantity: Mapped[Decimal] = mapped_column(QTY)
    unit_cost: Mapped[Decimal] = mapped_column(MONEY)

    order: Mapped[PurchaseOrder] = relationship(back_populates="lines")

    __table_args__ = (UniqueConstraint("order_id", "line_no", name="uq_po_line"),)


# ----------------------------------------------------------------- inventory
class InventoryMovement(Base):
    __tablename__ = "inventory_movement"

    id: Mapped[int] = mapped_column(primary_key=True)
    product_id: Mapped[int] = mapped_column(ForeignKey("product.id"), index=True)
    warehouse_id: Mapped[int] = mapped_column(ForeignKey("warehouse.id"), index=True)
    movement_type: Mapped[MovementType] = mapped_column(
        Enum(MovementType, name="movement_type")
    )
    quantity: Mapped[Decimal] = mapped_column(QTY)  # signed: + in, - out
    reference: Mapped[str | None] = mapped_column(String(64))
    moved_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), index=True
    )


# ------------------------------------------------------------------- finance
class GLEntry(Base):
    """Minimal double-entry ledger: every posting writes a balanced batch."""

    __tablename__ = "gl_entry"

    id: Mapped[int] = mapped_column(primary_key=True)
    batch_id: Mapped[str] = mapped_column(String(36), index=True)
    account_code: Mapped[str] = mapped_column(String(16), index=True)
    posting_date: Mapped[date] = mapped_column(Date, default=date.today, index=True)
    debit: Mapped[Decimal] = mapped_column(MONEY, default=0)
    credit: Mapped[Decimal] = mapped_column(MONEY, default=0)
    description: Mapped[str | None] = mapped_column(String(240))
    source_doc: Mapped[str | None] = mapped_column(String(32))

    __table_args__ = (
        CheckConstraint("debit >= 0 AND credit >= 0", name="ck_gl_nonneg"),
        CheckConstraint("(debit = 0) <> (credit = 0)", name="ck_gl_one_side_only"),
    )
