"""Business logic. Kept out of the routers so it is unit-testable without HTTP.

Interview talking point: the *reason* this layer exists is that the pipeline's
unit-test stage must run with no Azure dependency at all. Routers touch HTTP,
services touch the DB session, and nothing touches Azure SDKs directly.
"""
from __future__ import annotations

import uuid
from datetime import date
from decimal import Decimal

from sqlalchemy import func, select
from sqlalchemy.orm import Session, selectinload

from app.models.erp import (
    GLEntry,
    InventoryMovement,
    MovementType,
    OrderStatus,
    Product,
    PurchaseOrder,
    PurchaseOrderLine,
    SalesOrder,
    SalesOrderLine,
)

# Chart of accounts (tiny on purpose)
ACC_AR = "1100"  # Accounts receivable
ACC_INVENTORY = "1300"
ACC_AP = "2100"  # Accounts payable
ACC_REVENUE = "4000"
ACC_COGS = "5000"


class DomainError(Exception):
    """Raised for rule violations; routers translate these to HTTP 409/400."""


# --------------------------------------------------------------- numbering
def next_document_number(db: Session, prefix: str, table) -> str:
    year = date.today().year
    count = db.execute(select(func.count()).select_from(table)).scalar_one()
    return f"{prefix}-{year}-{count + 1:06d}"


# ------------------------------------------------------------- sales orders
def create_sales_order(db: Session, payload) -> SalesOrder:
    order = SalesOrder(
        order_no=next_document_number(db, "SO", SalesOrder),
        customer_id=payload.customer_id,
        warehouse_id=payload.warehouse_id,
        order_date=payload.order_date or date.today(),
        currency=payload.currency,
        status=OrderStatus.draft,
    )
    total = Decimal(0)
    for idx, line in enumerate(payload.lines, start=1):
        product = db.get(Product, line.product_id)
        if product is None or not product.is_active:
            raise DomainError(f"product {line.product_id} not found or inactive")
        price = line.unit_price if line.unit_price is not None else product.unit_price
        sol = SalesOrderLine(
            line_no=idx,
            product_id=product.id,
            quantity=line.quantity,
            unit_price=price,
            discount_pct=line.discount_pct,
        )
        order.lines.append(sol)
        total += (line.quantity * price) * (1 - line.discount_pct / 100)

    order.total_amount = total.quantize(Decimal("0.0001"))
    db.add(order)
    db.commit()
    db.refresh(order)
    return order


def get_sales_order(db: Session, order_id: int) -> SalesOrder | None:
    return db.execute(
        select(SalesOrder)
        .options(selectinload(SalesOrder.lines))
        .where(SalesOrder.id == order_id)
    ).scalar_one_or_none()


ALLOWED_TRANSITIONS: dict[OrderStatus, set[OrderStatus]] = {
    OrderStatus.draft: {OrderStatus.confirmed, OrderStatus.cancelled},
    OrderStatus.confirmed: {OrderStatus.picked, OrderStatus.cancelled},
    OrderStatus.picked: {OrderStatus.shipped},
    OrderStatus.shipped: {OrderStatus.invoiced},
    OrderStatus.invoiced: set(),
    OrderStatus.cancelled: set(),
}


def transition_sales_order(db: Session, order: SalesOrder, new: OrderStatus) -> SalesOrder:
    if new not in ALLOWED_TRANSITIONS[order.status]:
        raise DomainError(f"cannot move order from {order.status.value} to {new.value}")

    if new == OrderStatus.shipped:
        _issue_stock_for_order(db, order)
    if new == OrderStatus.invoiced:
        post_sales_invoice(db, order)

    order.status = new
    db.commit()
    db.refresh(order)
    return order


def _issue_stock_for_order(db: Session, order: SalesOrder) -> None:
    for line in order.lines:
        on_hand = stock_on_hand(db, line.product_id, order.warehouse_id)
        if on_hand < line.quantity:
            raise DomainError(
                f"insufficient stock for product {line.product_id}: "
                f"on hand {on_hand}, required {line.quantity}"
            )
        db.add(
            InventoryMovement(
                product_id=line.product_id,
                warehouse_id=order.warehouse_id,
                movement_type=MovementType.issue,
                quantity=-line.quantity,
                reference=order.order_no,
            )
        )
    db.flush()


# ---------------------------------------------------------- purchase orders
def create_purchase_order(db: Session, payload) -> PurchaseOrder:
    po = PurchaseOrder(
        po_no=next_document_number(db, "PO", PurchaseOrder),
        supplier_id=payload.supplier_id,
        warehouse_id=payload.warehouse_id,
        status=OrderStatus.draft,
    )
    total = Decimal(0)
    for idx, line in enumerate(payload.lines, start=1):
        if db.get(Product, line.product_id) is None:
            raise DomainError(f"product {line.product_id} not found")
        po.lines.append(
            PurchaseOrderLine(
                line_no=idx,
                product_id=line.product_id,
                quantity=line.quantity,
                unit_cost=line.unit_cost,
            )
        )
        total += line.quantity * line.unit_cost
    po.total_amount = total
    db.add(po)
    db.commit()
    db.refresh(po)
    return po


def receive_purchase_order(db: Session, po: PurchaseOrder) -> PurchaseOrder:
    if po.status not in (OrderStatus.draft, OrderStatus.confirmed):
        raise DomainError(f"purchase order already {po.status.value}")
    batch = str(uuid.uuid4())
    for line in po.lines:
        db.add(
            InventoryMovement(
                product_id=line.product_id,
                warehouse_id=po.warehouse_id,
                movement_type=MovementType.receipt,
                quantity=line.quantity,
                reference=po.po_no,
            )
        )
    # Dr Inventory / Cr Accounts payable
    _post_balanced(
        db,
        batch,
        po.total_amount,
        debit_account=ACC_INVENTORY,
        credit_account=ACC_AP,
        description=f"Goods receipt {po.po_no}",
        source_doc=po.po_no,
    )
    po.status = OrderStatus.confirmed
    db.commit()
    db.refresh(po)
    return po


# ----------------------------------------------------------------- inventory
def record_movement(db: Session, payload) -> InventoryMovement:
    if payload.movement_type == MovementType.issue and payload.quantity > 0:
        payload.quantity = -payload.quantity
    mv = InventoryMovement(
        product_id=payload.product_id,
        warehouse_id=payload.warehouse_id,
        movement_type=payload.movement_type,
        quantity=payload.quantity,
        reference=payload.reference,
    )
    db.add(mv)
    db.commit()
    db.refresh(mv)
    return mv


def stock_on_hand(db: Session, product_id: int, warehouse_id: int) -> Decimal:
    total = db.execute(
        select(func.coalesce(func.sum(InventoryMovement.quantity), 0)).where(
            InventoryMovement.product_id == product_id,
            InventoryMovement.warehouse_id == warehouse_id,
        )
    ).scalar_one()
    return Decimal(total)


def stock_levels(db: Session, warehouse_id: int) -> list[dict]:
    rows = db.execute(
        select(
            Product.id,
            Product.sku,
            Product.reorder_point,
            func.coalesce(func.sum(InventoryMovement.quantity), 0).label("on_hand"),
        )
        .outerjoin(
            InventoryMovement,
            (InventoryMovement.product_id == Product.id)
            & (InventoryMovement.warehouse_id == warehouse_id),
        )
        .group_by(Product.id, Product.sku, Product.reorder_point)
        .order_by(Product.sku)
    ).all()
    return [
        {
            "product_id": r.id,
            "sku": r.sku,
            "warehouse_id": warehouse_id,
            "on_hand": Decimal(r.on_hand),
            "reorder_point": r.reorder_point,
            "below_reorder": Decimal(r.on_hand) < r.reorder_point,
        }
        for r in rows
    ]


# ------------------------------------------------------------------- finance
def _post_balanced(
    db: Session,
    batch_id: str,
    amount: Decimal,
    *,
    debit_account: str,
    credit_account: str,
    description: str,
    source_doc: str | None = None,
) -> None:
    if amount <= 0:
        raise DomainError("posting amount must be positive")
    db.add_all(
        [
            GLEntry(
                batch_id=batch_id,
                account_code=debit_account,
                debit=amount,
                credit=Decimal(0),
                description=description,
                source_doc=source_doc,
            ),
            GLEntry(
                batch_id=batch_id,
                account_code=credit_account,
                debit=Decimal(0),
                credit=amount,
                description=description,
                source_doc=source_doc,
            ),
        ]
    )
    db.flush()


def post_sales_invoice(db: Session, order: SalesOrder) -> str:
    batch = str(uuid.uuid4())
    # Dr Accounts receivable / Cr Revenue
    _post_balanced(
        db,
        batch,
        order.total_amount,
        debit_account=ACC_AR,
        credit_account=ACC_REVENUE,
        description=f"Invoice for {order.order_no}",
        source_doc=order.order_no,
    )
    # Dr COGS / Cr Inventory at standard cost
    cogs = Decimal(0)
    for line in order.lines:
        product = db.get(Product, line.product_id)
        if product:
            cogs += line.quantity * product.standard_cost
    if cogs > 0:
        _post_balanced(
            db,
            batch,
            cogs,
            debit_account=ACC_COGS,
            credit_account=ACC_INVENTORY,
            description=f"COGS for {order.order_no}",
            source_doc=order.order_no,
        )
    return batch


def trial_balance(db: Session) -> list[dict]:
    rows = db.execute(
        select(
            GLEntry.account_code,
            func.coalesce(func.sum(GLEntry.debit), 0).label("d"),
            func.coalesce(func.sum(GLEntry.credit), 0).label("c"),
        )
        .group_by(GLEntry.account_code)
        .order_by(GLEntry.account_code)
    ).all()
    return [
        {
            "account_code": r.account_code,
            "debit_total": Decimal(r.d),
            "credit_total": Decimal(r.c),
            "balance": Decimal(r.d) - Decimal(r.c),
        }
        for r in rows
    ]
