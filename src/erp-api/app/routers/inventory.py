"""Inventory movements and stock levels."""
from decimal import Decimal

from fastapi import APIRouter, Depends, Query, status
from sqlalchemy.orm import Session

from app.core.db import get_db
from app.core.security import Principal, require_roles
from app.schemas import MovementIn, StockLevel
from app.services import record_movement, stock_levels, stock_on_hand

router = APIRouter(prefix="/inventory", tags=["inventory"])

INV_READ = ("erp.admin", "erp.reader", "erp.inventory", "erp.sales")
INV_WRITE = ("erp.admin", "erp.inventory")


@router.post("/movements", status_code=status.HTTP_201_CREATED)
def post_movement(
    payload: MovementIn,
    db: Session = Depends(get_db),
    _: Principal = Depends(require_roles(*INV_WRITE)),
):
    mv = record_movement(db, payload)
    return {"id": mv.id, "quantity": mv.quantity, "type": mv.movement_type}


@router.get("/stock", response_model=list[StockLevel])
def stock(
    warehouse_id: int = Query(gt=0),
    db: Session = Depends(get_db),
    _: Principal = Depends(require_roles(*INV_READ)),
):
    return stock_levels(db, warehouse_id)


@router.get("/stock/{product_id}")
def stock_for_product(
    product_id: int,
    warehouse_id: int = Query(gt=0),
    db: Session = Depends(get_db),
    _: Principal = Depends(require_roles(*INV_READ)),
) -> dict[str, Decimal | int]:
    return {
        "product_id": product_id,
        "warehouse_id": warehouse_id,
        "on_hand": stock_on_hand(db, product_id, warehouse_id),
    }
