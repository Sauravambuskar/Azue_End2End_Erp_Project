"""Sales order lifecycle: draft -> confirmed -> picked -> shipped -> invoiced."""
from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from app.core.db import get_db
from app.core.security import Principal, require_roles
from app.models.erp import OrderStatus, SalesOrder
from app.schemas import SalesOrderIn, SalesOrderOut, StatusChange
from app.services import DomainError, create_sales_order, get_sales_order, transition_sales_order

router = APIRouter(prefix="/sales-orders", tags=["sales"])

SALES_READ = ("erp.admin", "erp.reader", "erp.sales")
SALES_WRITE = ("erp.admin", "erp.sales")


@router.get("", response_model=list[SalesOrderOut])
def list_orders(
    db: Session = Depends(get_db),
    _: Principal = Depends(require_roles(*SALES_READ)),
    order_status: OrderStatus | None = Query(default=None, alias="status"),
    customer_id: int | None = Query(default=None, gt=0),
    limit: int = Query(default=25, ge=1, le=200),
):
    stmt = select(SalesOrder).options(selectinload(SalesOrder.lines))
    if order_status:
        stmt = stmt.where(SalesOrder.status == order_status)
    if customer_id:
        stmt = stmt.where(SalesOrder.customer_id == customer_id)
    stmt = stmt.order_by(SalesOrder.id.desc()).limit(limit)
    return db.execute(stmt).scalars().all()


@router.post("", response_model=SalesOrderOut, status_code=status.HTTP_201_CREATED)
def create_order(
    payload: SalesOrderIn,
    db: Session = Depends(get_db),
    principal: Principal = Depends(require_roles(*SALES_WRITE)),
):
    try:
        return create_sales_order(db, payload)
    except DomainError as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, str(exc)) from exc


@router.get("/{order_id}", response_model=SalesOrderOut)
def read_order(
    order_id: int,
    db: Session = Depends(get_db),
    _: Principal = Depends(require_roles(*SALES_READ)),
):
    order = get_sales_order(db, order_id)
    if order is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "sales order not found")
    return order


@router.post("/{order_id}/status", response_model=SalesOrderOut)
def change_status(
    order_id: int,
    payload: StatusChange,
    db: Session = Depends(get_db),
    _: Principal = Depends(require_roles(*SALES_WRITE)),
):
    order = get_sales_order(db, order_id)
    if order is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "sales order not found")
    try:
        return transition_sales_order(db, order, payload.status)
    except DomainError as exc:
        raise HTTPException(status.HTTP_409_CONFLICT, str(exc)) from exc
