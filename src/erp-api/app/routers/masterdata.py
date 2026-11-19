"""Master data CRUD: products, customers, suppliers, warehouses."""
from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.core.db import get_db
from app.core.security import Principal, require_roles
from app.models.erp import Customer, Product, Supplier, Warehouse
from app.schemas import (
    CustomerIn,
    CustomerOut,
    ProductIn,
    ProductOut,
    SupplierIn,
    SupplierOut,
    WarehouseIn,
    WarehouseOut,
)

router = APIRouter(tags=["master-data"])

READER = ("erp.admin", "erp.reader", "erp.sales", "erp.purchasing")
WRITER = ("erp.admin", "erp.masterdata")


# ------------------------------------------------------------------ products
@router.get("/products", response_model=list[ProductOut])
def list_products(
    db: Session = Depends(get_db),
    _: Principal = Depends(require_roles(*READER)),
    category: str | None = Query(default=None, max_length=64),
    active_only: bool = True,
    limit: int = Query(default=50, ge=1, le=500),
    offset: int = Query(default=0, ge=0),
):
    stmt = select(Product)
    if category:
        stmt = stmt.where(Product.category == category)
    if active_only:
        stmt = stmt.where(Product.is_active.is_(True))
    stmt = stmt.order_by(Product.sku).limit(limit).offset(offset)
    return db.execute(stmt).scalars().all()


@router.post("/products", response_model=ProductOut, status_code=status.HTTP_201_CREATED)
def create_product(
    payload: ProductIn,
    db: Session = Depends(get_db),
    _: Principal = Depends(require_roles(*WRITER)),
):
    product = Product(**payload.model_dump())
    db.add(product)
    try:
        db.commit()
    except IntegrityError as exc:
        db.rollback()
        raise HTTPException(
            status.HTTP_409_CONFLICT, f"SKU {payload.sku} already exists"
        ) from exc
    db.refresh(product)
    return product


@router.get("/products/{product_id}", response_model=ProductOut)
def get_product(
    product_id: int,
    db: Session = Depends(get_db),
    _: Principal = Depends(require_roles(*READER)),
):
    product = db.get(Product, product_id)
    if product is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "product not found")
    return product


@router.delete("/products/{product_id}", status_code=status.HTTP_204_NO_CONTENT)
def deactivate_product(
    product_id: int,
    db: Session = Depends(get_db),
    _: Principal = Depends(require_roles("erp.admin")),
):
    product = db.get(Product, product_id)
    if product is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "product not found")
    product.is_active = False  # soft delete: ERP data is never hard-deleted
    db.commit()


# ----------------------------------------------------------------- customers
@router.get("/customers", response_model=list[CustomerOut])
def list_customers(
    db: Session = Depends(get_db),
    _: Principal = Depends(require_roles(*READER)),
    limit: int = Query(default=50, ge=1, le=500),
):
    return db.execute(select(Customer).order_by(Customer.code).limit(limit)).scalars().all()


@router.post("/customers", response_model=CustomerOut, status_code=201)
def create_customer(
    payload: CustomerIn,
    db: Session = Depends(get_db),
    _: Principal = Depends(require_roles(*WRITER)),
):
    customer = Customer(**payload.model_dump())
    db.add(customer)
    try:
        db.commit()
    except IntegrityError as exc:
        db.rollback()
        raise HTTPException(409, f"customer {payload.code} already exists") from exc
    db.refresh(customer)
    return customer


# ----------------------------------------------------------------- suppliers
@router.get("/suppliers", response_model=list[SupplierOut])
def list_suppliers(
    db: Session = Depends(get_db),
    _: Principal = Depends(require_roles(*READER)),
):
    return db.execute(select(Supplier).order_by(Supplier.code)).scalars().all()


@router.post("/suppliers", response_model=SupplierOut, status_code=201)
def create_supplier(
    payload: SupplierIn,
    db: Session = Depends(get_db),
    _: Principal = Depends(require_roles(*WRITER)),
):
    supplier = Supplier(**payload.model_dump())
    db.add(supplier)
    try:
        db.commit()
    except IntegrityError as exc:
        db.rollback()
        raise HTTPException(409, f"supplier {payload.code} already exists") from exc
    db.refresh(supplier)
    return supplier


# ---------------------------------------------------------------- warehouses
@router.get("/warehouses", response_model=list[WarehouseOut])
def list_warehouses(
    db: Session = Depends(get_db),
    _: Principal = Depends(require_roles(*READER)),
):
    return db.execute(select(Warehouse).order_by(Warehouse.code)).scalars().all()


@router.post("/warehouses", response_model=WarehouseOut, status_code=201)
def create_warehouse(
    payload: WarehouseIn,
    db: Session = Depends(get_db),
    _: Principal = Depends(require_roles(*WRITER)),
):
    warehouse = Warehouse(**payload.model_dump())
    db.add(warehouse)
    try:
        db.commit()
    except IntegrityError as exc:
        db.rollback()
        raise HTTPException(409, f"warehouse {payload.code} already exists") from exc
    db.refresh(warehouse)
    return warehouse
