"""OIDC bearer-token validation.

Works with BOTH identity providers used in this project:
  * Microsoft Entra ID  (issuer https://login.microsoftonline.com/<tid>/v2.0)
  * Okta                (issuer https://<org>.okta.com/oauth2/default)

Both are plain OIDC, so one validator handles them. Roles/groups come from the
"roles" (Entra app roles) or "groups" (Okta) claim.
"""
import time
from typing import Any

import httpx
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jose import jwt

from app.core.config import get_settings

bearer = HTTPBearer(auto_error=False)
_jwks_cache: dict[str, Any] = {"keys": None, "exp": 0}


def _jwks(uri: str) -> dict:
    if _jwks_cache["keys"] and _jwks_cache["exp"] > time.time():
        return _jwks_cache["keys"]
    resp = httpx.get(uri, timeout=5.0)
    resp.raise_for_status()
    _jwks_cache.update(keys=resp.json(), exp=time.time() + 3600)
    return _jwks_cache["keys"]


class Principal:
    def __init__(self, claims: dict):
        self.claims = claims
        self.subject: str = claims.get("sub", "anonymous")
        self.name: str = claims.get("name") or claims.get("preferred_username", "anonymous")
        self.roles: list[str] = list(claims.get("roles") or claims.get("groups") or [])

    def require(self, *roles: str) -> None:
        if not roles:
            return
        if not set(roles) & set(self.roles):
            raise HTTPException(
                status.HTTP_403_FORBIDDEN,
                detail=f"requires one of roles: {', '.join(roles)}",
            )


def current_principal(
    creds: HTTPAuthorizationCredentials | None = Depends(bearer),
) -> Principal:
    settings = get_settings()
    if not settings.auth_enabled:
        # Local/dev mode: everyone is an admin so you can explore the API.
        return Principal({"sub": "dev", "name": "dev-user", "roles": ["erp.admin"]})

    if creds is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="missing bearer token")

    try:
        claims = jwt.decode(
            creds.credentials,
            _jwks(settings.oidc_jwks_uri),
            algorithms=["RS256"],
            audience=settings.oidc_audience,
            issuer=settings.oidc_issuer,
        )
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED, detail=f"invalid token: {exc}"
        ) from exc
    return Principal(claims)


def require_roles(*roles: str):
    def _dep(principal: Principal = Depends(current_principal)) -> Principal:
        principal.require(*roles)
        return principal

    return _dep
