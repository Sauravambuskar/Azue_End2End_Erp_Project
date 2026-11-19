"""Database engine with passwordless (Entra ID) auth support.

In Azure we authenticate to Azure Database for PostgreSQL Flexible Server with
an AAD access token obtained from the pod's Workload Identity. No password is
ever stored. Locally we fall back to a password from .env.
"""
import logging
from collections.abc import Iterator
from functools import lru_cache

from sqlalchemy import create_engine, event
from sqlalchemy.engine import Engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from app.core.config import get_settings

log = logging.getLogger(__name__)
settings = get_settings()

# Resource scope for Azure Database for PostgreSQL
PG_AAD_SCOPE = "https://ossrdbms-aad.database.windows.net/.default"


class Base(DeclarativeBase):
    pass


def _build_engine():
    engine = create_engine(
        settings.sqlalchemy_url,
        pool_pre_ping=True,
        pool_size=5,
        max_overflow=10,
        pool_recycle=1800,
        echo=False,
    )

    if settings.db_use_managed_identity:
        # Imported lazily and on purpose: the CI unit-test stage must run with
        # no Azure SDK installed and no cloud reachable.
        from azure.identity import DefaultAzureCredential

        credential = DefaultAzureCredential(exclude_interactive_browser_credential=True)

        @event.listens_for(engine, "do_connect")
        def _provide_token(dialect, conn_rec, cargs, cparams):  # noqa: ANN001
            token = credential.get_token(PG_AAD_SCOPE).token
            cparams["password"] = token
            log.debug("Injected AAD token for PostgreSQL connection")

    return engine


@lru_cache(maxsize=1)
def get_engine() -> Engine:
    """Engine is created on first use, never at import time.

    Import-time engine creation would force a PostgreSQL driver to be present
    in the CI unit-test stage, which runs against SQLite with no Azure SDKs.
    """
    return _build_engine()


@lru_cache(maxsize=1)
def get_sessionmaker() -> sessionmaker:
    return sessionmaker(bind=get_engine(), autoflush=False, expire_on_commit=False)


def get_db() -> Iterator[Session]:
    db = get_sessionmaker()()
    try:
        yield db
    finally:
        db.close()
