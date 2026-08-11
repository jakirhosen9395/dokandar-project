"""RS256 JWT verifier for authenticated REST routes."""
from __future__ import annotations

import base64
import logging
from typing import Annotated

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.config import settings


log = logging.getLogger("reporting.auth")

_bearer = HTTPBearer(auto_error=False, description="Bearer JWT (RS256)")


def _public_key() -> str:
    if not settings.jwt_public_key_b64:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, detail={
            "error": {"code": "server_misconfigured",
                      "message": "JWT_PUBLIC_KEY_B64 not configured"}
        })
    return base64.b64decode(settings.jwt_public_key_b64).decode("utf-8")


def require_user(
    creds: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
) -> dict:
    if creds is None or creds.scheme.lower() != "bearer":
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail={
            "error": {"code": "missing_token", "message": "Bearer token required"}
        })
    try:
        payload = jwt.decode(
            creds.credentials, _public_key(),
            algorithms=["RS256"], issuer=settings.jwt_issuer,
            options={"require": ["exp", "iat", "sub"]},
        )
    except jwt.PyJWTError as e:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail={
            "error": {"code": "invalid_token", "message": "invalid or expired token"}
        }) from e
    return payload


_SHOPKEEPER_ROLES = {"shopkeeper", "shop_staff", "admin", "platform_staff"}
_ADMIN_ROLES = {"admin", "platform_staff"}


def require_shopkeeper(user: Annotated[dict, Depends(require_user)]) -> dict:
    role = (user.get("role") or "").lower()
    if role not in _SHOPKEEPER_ROLES:
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail={
            "error": {"code": "insufficient_role",
                      "message": "shopkeeper or admin required"}
        })
    return user


def require_admin(user: Annotated[dict, Depends(require_user)]) -> dict:
    role = (user.get("role") or "").lower()
    if role not in _ADMIN_ROLES:
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail={
            "error": {"code": "insufficient_role",
                      "message": "admin or platform_staff required"}
        })
    return user
