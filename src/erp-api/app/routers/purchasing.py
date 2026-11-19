"""Purchase orders and goods receipt."""
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from app.core.db import get_db
from app.core.security import Principal, require_roles
from app.models.erp import PurchaseOrder
from app.schemas import PurchaseOrderIn, PurchaseOrderOut
from app.services import DomainError, create_purchase_order, receive_purchase_order

router = APIRouter(prefix="/purchase-orders", tags=["purchasing"])

PO_READ = ("erp.admin", "erp.reader", "erp.purchasing")
PO_WRITE = ("erp.admin", "erp.purchasing")


@router.get("", response_model=list[PurchaseOrderOut])
def list_pos(
    db: Session = Depends(get_db),
    _: Principal = Depends(require_roles(*PO_READ)),
):
    return db.execute(
        select(PurchaseOrder).order_by(PurchaseOrder.id.desc()).limit(50)
    ).scalars().all()


@router.post("", response_model=PurchaseOrderOut, status_code=status.HTTP_201_CREATED)
def create_po(
    payload: PurchaseOrderIn,
    db: Session = Depends(get_db),
    _: Principal = Depends(require_roles(*PO_WRITE)),
):
    try:
        return create_purchase_order(db, payload)
    except DomainError as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, str(exc)) from exc


@router.post("/{po_id}/receive", response_model=PurchaseOrderOut)
def receive(
    po_id: int,
    db: Session = Depends(get_db),
    _: Principal = Depends(require_roles(*PO_WRITE)),
):
    po = db.execute(
        select(PurchaseOrder)
        .options(selectinload(PurchaseOrder.lines))
        .where(PurchaseOrder.id == po_id)
    ).scalar_one_or_none()
    if po is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "purchase order not found")
    try:
        return receive_purchase_order(db, po)
    except DomainError as exc:
        raise HTTPException(status.HTTP_409_CONFLICT, str(exc)) from exc
