"""Constant-time x-internal-token check for east-west callers.

The validate endpoint is called by cart and order during checkout. The fleet's
east-west secret is INTERNAL_SERVICE_TOKEN; we compare it in constant time
(hmac.compare_digest). If the token is not configured (e.g. local dev), we
allow the request through with a warning — the caller's fail-open policy keeps
checkout flowing.
"""
from __future__ import annotations

import hmac
import logging
from typing import Annotated, Optional

from fastapi import Header, HTTPException, status

from app.config import settings


log = logging.getLogger("reco.internal")


def require_internal_token(
    x_internal_token: Annotated[Optional[str], Header(alias="x-internal-token")] = None,
) -> None:
    """Constant-time compare. If INTERNAL_SERVICE_TOKEN is empty (dev), skip."""
    expected = settings.internal_service_token
    if not expected:
        # not configured — allow through (caller still fail-open if blocked)
        log.warning("INTERNAL_SERVICE_TOKEN is empty — accepting unauthenticated /validate")
        return
    if not x_internal_token or not hmac.compare_digest(x_internal_token, expected):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail={
            "error": {"code": "unauthorized",
                      "message": "x-internal-token missing or invalid"}
        })
