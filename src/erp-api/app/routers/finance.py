"""General ledger reporting."""
from fastapi import APIRouter, Depends, Query
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.db import get_db
from app.core.security import Principal, require_roles
from app.models.erp import GLEntry
from app.schemas import GLEntryOut, TrialBalanceRow
from app.services import trial_balance

router = APIRouter(prefix="/finance", tags=["finance"])

FIN_READ = ("erp.admin", "erp.finance", "erp.reader")


@router.get("/gl", response_model=list[GLEntryOut])
def gl_entries(
    db: Session = Depends(get_db),
    _: Principal = Depends(require_roles(*FIN_READ)),
    account_code: str | None = Query(default=None, max_length=16),
    limit: int = Query(default=100, ge=1, le=1000),
):
    stmt = select(GLEntry)
    if account_code:
        stmt = stmt.where(GLEntry.account_code == account_code)
    return db.execute(stmt.order_by(GLEntry.id.desc()).limit(limit)).scalars().all()


@router.get("/trial-balance", response_model=list[TrialBalanceRow])
def get_trial_balance(
    db: Session = Depends(get_db),
    _: Principal = Depends(require_roles(*FIN_READ)),
):
    return trial_balance(db)
