# HAND-AUTHORED platform primitive (NOT dkdgen-generated).
# PL-06 — full error -> HTTP status vocabulary (EF-API-3).
"""The complete canon error -> HTTP status mapping (EF-API-3).

errors.py ships the coarse trio (ValidationError 400 / BusinessError 409 / InfrastructureError 503).
The API standard needs a richer vocabulary, so this module reuses those bases and adds the rest,
plus `status_for()` and `response_headers()` that a global exception handler applies uniformly:

    400  MalformedRequestError       malformed / unparseable request (syntactic)
    422  BusinessValidationError     well-formed but fails a business rule (semantic)
    403  AuthorizationError          authz denied / four-eyes approver missing
    409  StateConflictError          aggregate-state / idempotency-key mismatch
    423  LockedError                 park-and-freeze / custody or wallet fence
    429  RateLimitError              throttled (carries Retry-After)
    202  AsyncAcceptedError          accepted, settling async (escrow / payout)
    503  InfrastructureError         dependency unavailable

Split note: `ValidationError` (400) now means *malformed*; business-rule failures raise the new
`BusinessValidationError` (422) — the two were conflated under 400 before.
"""
from __future__ import annotations

from typing import Dict

from .errors import BusinessError, DokandarError, InfrastructureError, ValidationError

# --- HTTP status constants (the canon vocabulary) ------------------------------------------------
HTTP_ACCEPTED = 202
HTTP_BAD_REQUEST = 400
HTTP_FORBIDDEN = 403
HTTP_CONFLICT = 409
HTTP_UNPROCESSABLE = 422
HTTP_LOCKED = 423
HTTP_TOO_MANY_REQUESTS = 429
HTTP_UNAVAILABLE = 503


class MalformedRequestError(ValidationError):
    """400 — syntactically malformed / unparseable request (alias of the 400 base)."""
    http_status = HTTP_BAD_REQUEST


class BusinessValidationError(DokandarError):
    """422 — well-formed request that violates a business rule (the split-out half of 400)."""
    http_status = HTTP_UNPROCESSABLE


class AuthorizationError(DokandarError):
    """403 — authorization denied, or a four-eyes second approver is missing/identical."""
    http_status = HTTP_FORBIDDEN


class StateConflictError(BusinessError):
    """409 — aggregate-state conflict OR Idempotency-Key reused with a different payload."""
    http_status = HTTP_CONFLICT


class LockedError(DokandarError):
    """423 — resource parked/frozen: custody park-and-freeze or a wallet/escrow fence."""
    http_status = HTTP_LOCKED


class RateLimitError(DokandarError):
    """429 — throttled. `retry_after` seconds surfaces as the Retry-After header."""
    http_status = HTTP_TOO_MANY_REQUESTS

    def __init__(self, code: str, message: str, retry_after: int = 1, detail: str | None = None):
        super().__init__(code, message, detail)
        self.retry_after = retry_after


class AsyncAcceptedError(DokandarError):
    """202 — accepted and settling asynchronously (escrow capture / payout in flight)."""
    http_status = HTTP_ACCEPTED


def status_for(exc: Exception) -> int:
    """The HTTP status for any DokandarError (subclass `http_status`); 500 for anything else."""
    if isinstance(exc, DokandarError):
        return exc.http_status
    return 500


def response_headers(exc: Exception) -> Dict[str, str]:
    """Extra HTTP headers a status implies — Retry-After for 429, empty otherwise."""
    if isinstance(exc, RateLimitError):
        return {"Retry-After": str(max(0, int(exc.retry_after)))}
    return {}


# Static map for tests / documentation: exception type -> canon HTTP status.
STATUS_MAP: Dict[type, int] = {
    MalformedRequestError: HTTP_BAD_REQUEST,
    ValidationError: HTTP_BAD_REQUEST,
    BusinessValidationError: HTTP_UNPROCESSABLE,
    AuthorizationError: HTTP_FORBIDDEN,
    StateConflictError: HTTP_CONFLICT,
    BusinessError: HTTP_CONFLICT,
    LockedError: HTTP_LOCKED,
    RateLimitError: HTTP_TOO_MANY_REQUESTS,
    AsyncAcceptedError: HTTP_ACCEPTED,
    InfrastructureError: HTTP_UNAVAILABLE,
}
