"""Probe endpoints.

Kubernetes contract used by this project:
  /healthz/live   -> liveness.  Must NOT touch the database. If the DB is down
                     we do not want AKS to kill otherwise-healthy pods.
  /healthz/ready  -> readiness. Touches the DB, so a pod drops out of the
                     Service endpoints when its dependency is unavailable.
  /healthz/startup-> startup probe, gives slow cold starts room to breathe.
"""
import os

from fastapi import APIRouter, Depends, Response, status
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.core.config import get_settings
from app.core.db import get_db
from app.schemas import HealthOut

router = APIRouter(prefix="/healthz", tags=["health"])
VERSION = os.getenv("ERP_BUILD_VERSION", "0.0.0-local")


@router.get("/live", response_model=HealthOut)
def live() -> HealthOut:
    s = get_settings()
    return HealthOut(
        status="ok",
        service=s.service_name,
        env=s.env,
        version=VERSION,
        database="not-checked",
    )


@router.get("/ready", response_model=HealthOut)
def ready(response: Response, db: Session = Depends(get_db)) -> HealthOut:
    s = get_settings()
    checks: dict[str, str] = {}
    db_state = "up"
    try:
        db.execute(text("SELECT 1"))
        checks["postgres"] = "ok"
    except Exception as exc:  # noqa: BLE001
        db_state = "down"
        checks["postgres"] = f"error: {type(exc).__name__}"
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    return HealthOut(
        status="ok" if db_state == "up" else "degraded",
        service=s.service_name,
        env=s.env,
        version=VERSION,
        database=db_state,
        checks=checks,
    )


@router.get("/startup", response_model=HealthOut)
def startup(response: Response, db: Session = Depends(get_db)) -> HealthOut:
    return ready(response, db)
