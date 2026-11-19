"""Configuration. Secrets never live in code or images.

Resolution order:
  1. Environment variables (K8s env / Container App env)
  2. Azure Key Vault via Workload Identity (no secret, no password)
  3. Local .env fallback for laptop development only
"""
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_prefix="ERP_", extra="ignore")

    # --- app ---
    env: str = "dev"
    service_name: str = "erp-api"
    log_level: str = "INFO"
    api_prefix: str = "/api/v1"

    # --- database ---
    # Managed-identity (passwordless) connection is preferred in Azure.
    db_host: str = "localhost"
    db_port: int = 5432
    db_name: str = "erp"
    db_user: str = "erpadmin"
    db_password: str | None = None           # only used locally / in CI
    db_use_managed_identity: bool = False       # True in Azure
    db_sslmode: str = "prefer"                  # "require" in Azure

    # --- azure ---
    key_vault_uri: str | None = None
    appinsights_connection_string: str | None = None
    servicebus_namespace: str | None = None
    servicebus_queue: str = "erp-events"

    # --- auth (Entra ID / Okta via OIDC) ---
    auth_enabled: bool = False
    oidc_issuer: str | None = None
    oidc_audience: str | None = None
    oidc_jwks_uri: str | None = None

    # Escape hatch for laptop development and CI: a full SQLAlchemy URL that
    # bypasses the Azure-shaped settings entirely, e.g.
    #   ERP_DB_URL=sqlite:///./erp-local.db
    # Never set this in Azure - the managed-identity path is the supported one.
    db_url: str | None = None

    @property
    def sqlalchemy_url(self) -> str:
        if self.db_url:
            return self.db_url
        if self.db_use_managed_identity:
            # password is injected at connect-time by get_aad_token()
            return (
                f"postgresql+psycopg://{self.db_user}@{self.db_host}:{self.db_port}"
                f"/{self.db_name}?sslmode=require"
            )
        pwd = self.db_password or ""
        return (
            f"postgresql+psycopg://{self.db_user}:{pwd}@{self.db_host}:{self.db_port}"
            f"/{self.db_name}?sslmode={self.db_sslmode}"
        )


@lru_cache
def get_settings() -> Settings:
    return Settings()
