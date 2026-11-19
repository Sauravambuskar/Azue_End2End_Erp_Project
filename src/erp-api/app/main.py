"""ContosoERP API - FastAPI entrypoint.

Security headers, CORS, request IDs, Prometheus metrics and Azure Monitor
tracing are all configured here so that every route inherits them.
"""
import logging
import time
import uuid
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from prometheus_fastapi_instrumentator import Instrumentator

from app.core.config import get_settings
from app.core.telemetry import configure_telemetry
from app.routers import finance, health, inventory, masterdata, purchasing, sales

settings = get_settings()
logging.basicConfig(
    level=settings.log_level,
    format='{"ts":"%(asctime)s","level":"%(levelname)s","logger":"%(name)s","msg":"%(message)s"}',
)
log = logging.getLogger("erp.api")


@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("starting %s in env=%s", settings.service_name, settings.env)
    yield
    log.info("shutting down %s", settings.service_name)


app = FastAPI(
    title="ContosoERP API",
    description=(
        "Enterprise ERP backend used as the workload for the Azure DevSecOps "
        "practice platform. Modules: master data, sales, purchasing, "
        "inventory, finance."
    ),
    version="1.0.0",
    lifespan=lifespan,
    docs_url="/docs" if settings.env != "prod" else None,
    redoc_url=None,
    openapi_url="/openapi.json",
)

# CORS: in prod the web tier is same-origin behind App Gateway, so keep this tight.
allowed_origins = ["*"] if settings.env == "dev" else ["https://erp.contoso-lab.com"]
app.add_middleware(
    CORSMiddleware,
    allow_origins=allowed_origins,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE"],
    allow_headers=["Authorization", "Content-Type", "X-Request-Id"],
)

SECURITY_HEADERS = {
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
    "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
    "Permissions-Policy": "geolocation=(), microphone=(), camera=()",
}


@app.middleware("http")
async def observability_and_headers(request: Request, call_next):
    request_id = request.headers.get("X-Request-Id", str(uuid.uuid4()))
    started = time.perf_counter()
    response = await call_next(request)
    elapsed_ms = (time.perf_counter() - started) * 1000
    response.headers["X-Request-Id"] = request_id
    response.headers["X-Response-Time-Ms"] = f"{elapsed_ms:.1f}"
    for key, value in SECURITY_HEADERS.items():
        response.headers.setdefault(key, value)
    log.info(
        "%s %s -> %s in %.1fms rid=%s",
        request.method,
        request.url.path,
        response.status_code,
        elapsed_ms,
        request_id,
    )
    return response


@app.exception_handler(Exception)
async def unhandled(request: Request, exc: Exception):
    # Never leak stack traces to the caller - that is an OWASP A05 finding.
    log.exception("unhandled error on %s", request.url.path)
    return JSONResponse(status_code=500, content={"detail": "internal server error"})


configure_telemetry(app)
Instrumentator().instrument(app).expose(app, endpoint="/metrics", include_in_schema=False)

app.include_router(health.router)
prefix = settings.api_prefix
app.include_router(masterdata.router, prefix=prefix)
app.include_router(sales.router, prefix=prefix)
app.include_router(purchasing.router, prefix=prefix)
app.include_router(inventory.router, prefix=prefix)
app.include_router(finance.router, prefix=prefix)


@app.get("/", include_in_schema=False)
def root():
    return {
        "service": settings.service_name,
        "env": settings.env,
        "docs": "/docs",
        "health": "/healthz/ready",
    }
