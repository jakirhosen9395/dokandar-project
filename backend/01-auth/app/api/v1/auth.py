"""Auth API: signup / login / refresh / logout / me / users / jwks."""
from __future__ import annotations
import json
import logging
import re
import uuid
from datetime import datetime, timezone
from typing import Literal, Optional
import jwt
from fastapi import APIRouter, Depends, HTTPException, Path, Request, Response, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, EmailStr, Field, field_validator
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from app.config import settings
from app.db.models import KYCSubmission, Outbox, User
from app.db.session import session_scope, SessionLocal, get_session
from app.domain import otp as otp_mod, tokens as tok
from app.messaging import rabbitmq as rmq
from app.observability import metrics as M

log = logging.getLogger("auth.api")

# No router-level `tags=` here: each route declares its own tag
# (auth / kyc / admin) so the OpenAPI groups stay clean. A router-level tag
# would concatenate with the per-route tag (e.g. ["auth","kyc"]).
router = APIRouter(prefix="/api/v1/auth")

# HTTPBearer is wired into the OpenAPI spec as `securitySchemes.bearerJwt`
# (type=http, scheme=bearer, bearerFormat=JWT) — that lights up the green
# "Authorize" button in Swagger UI (/docs). The `scheme_name`/`bearerFormat`
# are OpenAPI-only metadata; runtime token extraction is unchanged.
# `auto_error=False` is deliberate: we want to return our own 401 envelope
# with `code=token_missing` instead of FastAPI's default 403 / 401 when no
# header is sent.
bearer_scheme = HTTPBearer(scheme_name="bearerJwt", bearerFormat="JWT", auto_error=False)

# ---------------------------------------------------------------------------
# Pydantic request/response models
# ---------------------------------------------------------------------------

PHONE_RE = re.compile(r"^01[3-9]\d{8}$")

SELF_SIGNUP_ROLES = {"customer"}
ALL_ROLES = {"admin", "shopkeeper", "shop_staff", "platform_staff", "customer"}
PROVISIONABLE_BY = {
    "admin": ALL_ROLES,                       # admin → any role
    "shopkeeper": {"shop_staff", "customer"}, # shopkeeper → staff + customers (own)
    "shop_staff": {"customer"},                # shop_staff → customer (walk-ins, §3.3)
}


# ---------------------------------------------------------------------------
# Shared OpenAPI error component. The platform error envelope is
# `{error:{code,message,request_id,details}}` with a lowercase snake `code`.
# This Pydantic model is DOC-ONLY: it is referenced from each route's
# `responses={...}` map so every documented 4xx/5xx renders the same schema.
# It is never used as a `response_model` (that would filter runtime bodies).
# ---------------------------------------------------------------------------

class _ErrorBody(BaseModel):
    code: str = Field(examples=["validation_error"], description="Stable machine-readable, lowercase snake_case code.")
    message: str = Field(examples=["Request body failed validation."], description="Human-readable message (scrubbed; never leaks internals).")
    request_id: Optional[str] = Field(default=None, examples=["b3a1f0c2d4e5"], description="Honour-or-mint x-request-id correlation id.")
    details: Optional[object] = Field(default=None, description="Optional structured context (e.g. per-field validation issues).")


class ErrorEnvelope(BaseModel):
    """Platform error envelope — `{error:{code,message,request_id,details}}`."""
    error: _ErrorBody


# Reusable `responses=` fragments (OpenAPI-only — no runtime effect).
def _resp(code: str, description: str) -> dict:
    return {code: {"model": ErrorEnvelope, "description": description}}


_R_401 = _resp("401", "Unauthenticated — token_missing / token_invalid / token_expired.")
_R_403 = _resp("403", "Forbidden — insufficient_role / account_suspended.")
_R_404 = _resp("404", "Not found.")
_R_409 = _resp("409", "Conflict — duplicate / already in target state.")
_R_422 = _resp("422", "Validation error.")
_R_429 = _resp("429", "Rate limited — too many OTP requests / attempts.")


def _err(code: str, message: str, status_code: int, details=None):
    body = {"error": {"code": code, "message": message, "request_id": None}}
    if details:
        body["error"]["details"] = details
    raise HTTPException(status_code=status_code, detail=body)


def _conflict_from_integrity(e: IntegrityError) -> None:
    """Map a unique-constraint violation to a 409 envelope. Covers a duplicate
    email (not pre-checked) and the race where two requests insert the same
    phone concurrently — without this they surface as a misleading
    503 dependency_unavailable (IntegrityError is a DBAPIError subclass and the
    global handler treats those as a dependency outage)."""
    detail = str(getattr(e, "orig", e)).lower()
    if "email" in detail:
        _err("email_already_registered", "This email is already registered.", 409)
    _err("phone_already_registered", "This phone is already registered.", 409)


class PhoneReq(BaseModel):
    phone: str = Field(
        examples=["01712345678"],
        description="Bangladesh mobile number — 11 digits, format 01[3-9] then 8 digits.",
    )

    @field_validator("phone")
    @classmethod
    def _phone(cls, v: str) -> str:
        v = v.strip()
        if not PHONE_RE.match(v):
            raise ValueError("phone must match ^01[3-9]\\d{8}$")
        return v


class SignupVerifyReq(BaseModel):
    phone: str = Field(examples=["01712345678"], description="The mobile number you sent the OTP to.")
    code: Optional[str] = Field(
        default=None, examples=["123456"],
        description="The 6-digit OTP from your SMS (or the support viewer). Required when OTP is enabled.",
    )
    name: str = Field(min_length=2, max_length=120, examples=["Rahim Uddin"])
    # Literal → Swagger renders a dropdown AND it validates server-side, while the
    # value stays a plain string (no enum-object leak into JSON / JWT / outbox).
    lang: Literal["bn", "en"] = Field(default="bn", description="Preferred language.")
    role: Literal["customer", "admin", "shopkeeper", "shop_staff", "platform_staff"] = Field(
        default="customer",
        description="Self-signup is only for 'customer'; any other role returns 403 role_not_self_serviceable.",
    )
    email: Optional[EmailStr] = Field(default=None, examples=["rahim@example.com"])

    @field_validator("phone")
    @classmethod
    def _phone(cls, v: str) -> str:
        if not PHONE_RE.match(v.strip()):
            raise ValueError("invalid phone")
        return v.strip()


class LoginVerifyReq(BaseModel):
    phone: str = Field(examples=["01712345678"], description="Your registered mobile number.")
    code: Optional[str] = Field(
        default=None, examples=["123456"],
        description="The 6-digit login OTP (required when OTP is enabled).",
    )


class RefreshReq(BaseModel):
    refresh_token: str = Field(
        examples=["paste-the-refresh_token-from-signup-or-login"],
        description="The refresh_token returned by signup/verify or login/verify.",
    )


class LogoutReq(BaseModel):
    refresh_token: str = Field(
        examples=["paste-the-refresh_token-to-revoke"],
        description="The refresh_token to revoke. Idempotent — already-revoked still returns 204.",
    )


class CreateUserReq(BaseModel):
    # `str` (not Literal) on purpose: which roles a caller may create is decided by
    # the RBAC matrix, so an unknown/not-allowed role must return 403
    # insufficient_role from the handler — NOT a 422. The json_schema_extra `enum`
    # only powers the Swagger dropdown; it does not tighten server validation.
    role: str = Field(
        examples=["shop_staff"],
        description="Role to provision. Your allowed set depends on your own role (the RBAC matrix).",
        json_schema_extra={"enum": ["customer", "admin", "shopkeeper", "shop_staff", "platform_staff"]},
    )
    phone: str = Field(examples=["01712345679"], description="New user's mobile number.")
    name: str = Field(min_length=2, max_length=120, examples=["Karim Mia"])
    email: Optional[EmailStr] = Field(default=None, examples=["karim@example.com"])

    @field_validator("phone")
    @classmethod
    def _phone(cls, v: str) -> str:
        if not PHONE_RE.match(v.strip()):
            raise ValueError("invalid phone")
        return v.strip()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _user_out(u: User) -> dict:
    return {
        "id": str(u.id), "phone": u.phone, "name": u.name,
        "email": u.email,
        "role": u.role, "status": u.status,
        "kyc": u.kyc, "lang": u.lang,
    }


def _token_response(access: str, refresh: str, user: User) -> dict:
    return {
        "access_token": access,
        "refresh_token": refresh,
        "token_type": "Bearer",
        "expires_in": settings.jwt_access_ttl_seconds,
        "user": _user_out(user),
    }


async def _emit_user_created(db: AsyncSession, u: User) -> None:
    db.add(Outbox(
        topic=settings.kafka_topic_user,
        key=str(u.id),
        payload={
            "event": "UserCreated",
            "user_id": str(u.id), "phone": u.phone, "role": u.role,
            "name": u.name, "email": u.email,
            "created_at": datetime.now(timezone.utc).isoformat(),
        },
    ))
    M.signups.labels(role=u.role).inc()


async def _send_otp(phone: str, purpose: str, code: str) -> None:
    """In dev with OTP_ENABLED, log the code (so it's visible in Mongo logs);
    always enqueue an SMS task to RabbitMQ for a notification worker."""
    if settings.app_env == "dev":
        log.warning("[DEV-OTP] phone=%s purpose=%s code=%s", phone, purpose, code)
    try:
        await rmq.enqueue_otp(phone, code, purpose)
    except Exception as e:
        log.warning("rabbitmq enqueue_otp failed: %s", e)


async def _current_user(
    creds: Optional[HTTPAuthorizationCredentials] = Depends(bearer_scheme),
    db: AsyncSession = Depends(get_session),
) -> User:
    # `creds is None` covers BOTH "no Authorization header at all" and
    # "Authorization header present but not the Bearer scheme" — HTTPBearer
    # with auto_error=False maps both to None. The token attribute is
    # already the raw JWT (HTTPBearer strips the "Bearer " prefix), so
    # never prepend it again before verification.
    if creds is None:
        _err("token_missing", "Missing Authorization: Bearer header", 401)
    token = creds.credentials
    try:
        claims = tok.verify_access_token(token)
    except jwt.ExpiredSignatureError:
        _err("token_expired", "Access token has expired (use /refresh)", 401)
    except jwt.PyJWTError as e:
        _err("token_invalid", f"Invalid access token ({e})", 401)
    u = (await db.execute(select(User).where(User.id == uuid.UUID(claims["sub"])))).scalar_one_or_none()
    if u is None:
        _err("token_invalid", "User no longer exists", 401)
    # Enforce suspension on every authenticated request. The access token is
    # stateless (≤15 min), and /refresh will happily mint new ones, so without
    # this re-check a suspended account would keep full access until expiry and
    # could refresh indefinitely. We re-query the user above, so this reflects
    # the live status, not the (possibly stale) token claim.
    if u.status == "suspended":
        _err("account_suspended", "Account is suspended.", 403)
    return u


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@router.post(
    "/signup/request", status_code=202, tags=["auth"],
    operation_id="signupRequest", summary="Send signup OTP to a phone",
    responses={**_R_409, **_R_422, **_R_429},
)
async def signup_request(req: PhoneReq):
    async with session_scope() as db:
        existing = (await db.execute(select(User).where(User.phone == req.phone))).scalar_one_or_none()
        if existing:
            _err("phone_already_registered", "This phone is already registered. Use /login/request.", 409)
    # OTP flow disabled (OTP_ENABLED=false): the /verify endpoints accept
    # any (or no) code, so /request becomes a no-op. Short-circuit before
    # touching Redis so the conditional /ready contract is honest — Redis
    # genuinely isn't on the traffic path in this mode.
    if not settings.otp_enabled:
        return {"status": "otp_disabled", "expires_in": 0}
    try:
        code = await otp_mod.request_otp(req.phone, purpose="signup")
    except PermissionError as e:
        _err("rate_limited", "Too many OTP requests. Try later.", 429)
    await _send_otp(req.phone, "signup", code)
    return {"status": "otp_sent", "expires_in": settings.otp_ttl_seconds}


@router.post(
    "/signup/verify", status_code=201, tags=["auth"],
    operation_id="signupVerify", summary="Verify OTP & create customer (returns tokens)",
    responses={**_R_401, **_R_403, **_R_409, **_R_422, **_R_429},
)
async def signup_verify(req: SignupVerifyReq, request: Request):
    if req.role not in SELF_SIGNUP_ROLES:
        _err("role_not_self_serviceable", f"Self-signup is only for role 'customer'; got {req.role!r}", 403)
    if settings.otp_enabled:
        if not req.code:
            _err("validation_error", "code is required when OTP_ENABLED=true", 422)
        try:
            ok = await otp_mod.verify_otp(req.phone, "signup", req.code)
        except PermissionError:
            _err("otp_max_attempts", "Too many wrong attempts.", 429)
        if not ok:
            _err("otp_invalid", "The code is incorrect or expired.", 401)
    try:
        async with session_scope() as db:
            if (await db.execute(select(User).where(User.phone == req.phone))).scalar_one_or_none():
                _err("phone_already_registered", "This phone is already registered.", 409)
            u = User(phone=req.phone, name=req.name, lang=req.lang,
                     role=req.role, email=req.email, status="active")
            db.add(u)
            await db.flush()
            await _emit_user_created(db, u)
            access, _ = tok.issue_access_token(u)
            refresh = await tok.issue_refresh_token(
                db, u, user_agent=request.headers.get("user-agent"),
                ip=request.client.host if request.client else None,
            )
    except IntegrityError as e:
        _conflict_from_integrity(e)
    return _token_response(access, refresh, u)


@router.post(
    "/login/request", status_code=202, tags=["auth"],
    operation_id="loginRequest", summary="Send login OTP (always 202 — anti-enumeration)",
    responses={**_R_422, **_R_429},
)
async def login_request(req: PhoneReq):
    # Always 202 — anti-enumeration
    #
    # When OTP_ENABLED=false, return the same 202 without touching Redis.
    # The /login/verify endpoint accepts any code in that mode, so /request
    # is informational only. Skipping Redis keeps the /ready contract
    # honest (Redis is not on the traffic path when OTP is off).
    if not settings.otp_enabled:
        return {"status": "otp_disabled", "expires_in": 0}
    try:
        async with session_scope() as db:
            exists = (await db.execute(select(User).where(User.phone == req.phone))).scalar_one_or_none()
        if exists:
            code = await otp_mod.request_otp(req.phone, purpose="login")
            await _send_otp(req.phone, "login", code)
        else:
            log.info("login/request for unknown phone=%s (anti-enum 202)", req.phone)
    except PermissionError:
        _err("rate_limited", "Too many OTP requests. Try later.", 429)
    return {"status": "otp_sent", "expires_in": settings.otp_ttl_seconds}


@router.post(
    "/login/verify", tags=["auth"],
    operation_id="loginVerify", summary="Verify login OTP (returns tokens)",
    responses={**_R_401, **_R_403, **_R_422, **_R_429},
)
async def login_verify(req: LoginVerifyReq, request: Request):
    if not PHONE_RE.match(req.phone or ""):
        _err("validation_error", "invalid phone", 422)
    if settings.otp_enabled:
        if not req.code:
            _err("validation_error", "code is required when OTP_ENABLED=true", 422)
        try:
            ok = await otp_mod.verify_otp(req.phone, "login", req.code)
        except PermissionError:
            _err("otp_max_attempts", "Too many wrong attempts.", 429)
        if not ok:
            _err("invalid_credentials", "Login failed.", 401)
    async with session_scope() as db:
        u = (await db.execute(select(User).where(User.phone == req.phone))).scalar_one_or_none()
        if u is None:
            _err("invalid_credentials", "Login failed.", 401)
        if u.status == "suspended":
            _err("account_suspended", "Account is suspended.", 403)
        access, _ = tok.issue_access_token(u)
        refresh = await tok.issue_refresh_token(
            db, u, user_agent=request.headers.get("user-agent"),
            ip=request.client.host if request.client else None,
        )
    return _token_response(access, refresh, u)


@router.post(
    "/refresh", tags=["auth"],
    operation_id="refreshToken", summary="Rotate refresh token (replay revokes the family)",
    responses={**_R_401, **_R_422},
)
async def refresh(req: RefreshReq, request: Request):
    if not req.refresh_token:
        _err("validation_error", "refresh_token required", 422)
    async with session_scope() as db:
        try:
            user, new_refresh, access = await tok.rotate_refresh_token(
                db, req.refresh_token,
                user_agent=request.headers.get("user-agent"),
                ip=request.client.host if request.client else None,
            )
        except PermissionError as e:
            code = str(e) if str(e) in {"refresh_invalid", "refresh_reuse_detected"} else "refresh_invalid"
            _err(code, "Refresh token rejected.", 401)
    return _token_response(access, new_refresh, user)


@router.post(
    "/logout", status_code=204, tags=["auth"],
    operation_id="logout", summary="Logout — revoke a refresh token (idempotent)",
    responses={**_R_422},
)
async def logout(req: LogoutReq, response: Response):
    if not req.refresh_token:
        _err("validation_error", "refresh_token required", 422)
    async with session_scope() as db:
        await tok.revoke_refresh_token(db, req.refresh_token)
    return Response(status_code=204)


@router.get(
    "/me", tags=["auth"],
    operation_id="getMe", summary="Current user (from the Bearer access token)",
    responses={**_R_401, **_R_403},
)
async def me(user: User = Depends(_current_user)):
    return _user_out(user)


@router.post(
    "/users", status_code=201, tags=["admin"],
    operation_id="createUser", summary="Provision a user (per the RBAC role matrix)",
    responses={**_R_401, **_R_403, **_R_409, **_R_422},
)
async def create_user(req: CreateUserReq, request: Request, actor: User = Depends(_current_user)):
    allowed = PROVISIONABLE_BY.get(actor.role, set())
    if req.role not in allowed:
        _err("insufficient_role",
             f"Your role {actor.role!r} cannot create {req.role!r}.", 403)
    try:
        async with session_scope() as db:
            if (await db.execute(select(User).where(User.phone == req.phone))).scalar_one_or_none():
                _err("phone_already_registered", "This phone is already registered.", 409)
            u = User(phone=req.phone, name=req.name, role=req.role, email=req.email,
                     status="active", created_by=actor.id)
            db.add(u)
            await db.flush()
            await _emit_user_created(db, u)
    except IntegrityError as e:
        _conflict_from_integrity(e)
    return {"user": _user_out(u)}


@router.get(
    "/jwks", tags=["auth"],
    operation_id="getJwks", summary="Public keys (JWKS) — verify auth's JWTs offline",
)
async def jwks():
    return tok.public_jwks()


# ---------------------------------------------------------------------------
# KYC submission flow (dokandar_docs/services/auth.md §5.3, §7.9–§7.13)
# ---------------------------------------------------------------------------

_KEY_PREFIX_PATTERN = re.compile(r"^kyc/[0-9a-f-]{36}/[^/].*$")


class KYCSubmitReq(BaseModel):
    nid_key: str = Field(
        examples=["kyc/REPLACE-WITH-YOUR-USER-ID/nid_front.jpg"],
        description="S3 object key of the uploaded NID, under your OWN kyc/<your-user-id>/ "
                    "prefix. Get your user id from GET /me and replace the placeholder.",
    )
    trade_license_key: Optional[str] = Field(
        default=None,
        examples=["kyc/REPLACE-WITH-YOUR-USER-ID/trade_license.pdf"],
        description="Optional. S3 key of the trade license, under your own kyc/<your-user-id>/ prefix.",
    )
    bank_account_last4: Optional[str] = Field(default=None, max_length=8, examples=["4321"])
    mobile_wallet_number: Optional[str] = Field(default=None, max_length=20, examples=["01712345678"])

    @field_validator("nid_key")
    @classmethod
    def _nid(cls, v: str) -> str:
        v = v.strip()
        if not v or "/" not in v or not v.startswith("kyc/"):
            raise ValueError("nid_key must live under 'kyc/<user_id>/'")
        return v

    @field_validator("trade_license_key")
    @classmethod
    def _tlk(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return v
        v = v.strip()
        if not v.startswith("kyc/"):
            raise ValueError("trade_license_key must live under 'kyc/<user_id>/'")
        return v


class KYCRejectReq(BaseModel):
    reason: str = Field(
        min_length=2, max_length=1000,
        examples=["Submitted NID image is illegible — please re-upload a clear photo."],
        description="Why the KYC submission is rejected (shown to the shopkeeper).",
    )


def _submission_out(s: KYCSubmission) -> dict:
    return {
        "submission_id":        str(s.id),
        "user_id":              str(s.user_id),
        "nid_key":              s.nid_key,
        "trade_license_key":    s.trade_license_key,
        "bank_account_last4":   s.bank_account_last4,
        "mobile_wallet_number": s.mobile_wallet_number,
        "submitted_at":         s.submitted_at.isoformat() if s.submitted_at else None,
        "reviewed_by":          str(s.reviewed_by) if s.reviewed_by else None,
        "reviewed_at":          s.reviewed_at.isoformat() if s.reviewed_at else None,
        "decision":             s.decision,
        "rejection_reason":     s.rejection_reason,
    }


@router.post(
    "/kyc/submit", status_code=202, tags=["kyc"],
    operation_id="submitKyc", summary="Submit KYC documents (shopkeeper only)",
    responses={**_R_401, **_R_403, **_R_409, **_R_422},
)
async def kyc_submit(req: KYCSubmitReq, user: User = Depends(_current_user)):
    # Spec §7.9: shopkeeper-only
    if user.role != "shopkeeper":
        _err("insufficient_role",
             "KYC submission is for shopkeepers only.", 403)
    # Each key must be in this user's own kyc/<user_id>/ prefix
    own_prefix = f"kyc/{user.id}/"
    if not req.nid_key.startswith(own_prefix):
        _err("validation_error",
             f"nid_key must start with {own_prefix!r}", 422,
             details=[{"field": "nid_key", "issue": "wrong_prefix"}])
    if req.trade_license_key and not req.trade_license_key.startswith(own_prefix):
        _err("validation_error",
             f"trade_license_key must start with {own_prefix!r}", 422,
             details=[{"field": "trade_license_key", "issue": "wrong_prefix"}])
    async with session_scope() as db:
        if user.kyc == "submitted":
            _err("kyc_already_submitted",
                 "A previous submission is already awaiting review.", 409)
        sub = KYCSubmission(
            user_id=user.id,
            nid_key=req.nid_key,
            trade_license_key=req.trade_license_key,
            bank_account_last4=req.bank_account_last4,
            mobile_wallet_number=req.mobile_wallet_number,
        )
        db.add(sub)
        # Flip the user's KYC status to 'submitted' in the same TX.
        u_in_tx = (await db.execute(
            select(User).where(User.id == user.id)
        )).scalar_one()
        u_in_tx.kyc = "submitted"
        await db.flush()
        db.add(Outbox(
            topic=settings.kafka_topic_kyc_submitted,
            key=str(user.id),
            payload={
                "event": "KycSubmitted",
                "submission_id": str(sub.id),
                "user_id":       str(user.id),
                "submitted_at":  datetime.now(timezone.utc).isoformat(),
            },
        ))
        M.kyc_submitted.inc()
    return {"status": "submitted", "submission_id": str(sub.id)}


@router.get(
    "/kyc/me", tags=["kyc"],
    operation_id="getMyKyc", summary="My latest KYC status & decision",
    responses={**_R_401, **_R_403},
)
async def kyc_me(user: User = Depends(_current_user), db: AsyncSession = Depends(get_session)):
    latest = (await db.execute(
        select(KYCSubmission)
        .where(KYCSubmission.user_id == user.id)
        .order_by(KYCSubmission.submitted_at.desc())
        .limit(1)
    )).scalar_one_or_none()
    if latest is None:
        return {
            "kyc": user.kyc,
            "submission_id": None,
            "submitted_at": None,
            "decision": None,
            "decided_at": None,
            "rejection_reason": None,
        }
    return {
        "kyc": user.kyc,
        "submission_id":    str(latest.id),
        "submitted_at":     latest.submitted_at.isoformat() if latest.submitted_at else None,
        "decision":         latest.decision,
        "decided_at":       latest.reviewed_at.isoformat() if latest.reviewed_at else None,
        "rejection_reason": latest.rejection_reason,
    }


@router.get(
    "/kyc/queue", tags=["kyc"],
    operation_id="getKycQueue", summary="Pending KYC queue (admin / platform_staff)",
    responses={**_R_401, **_R_403},
)
async def kyc_queue(
    actor: User = Depends(_current_user),
    db: AsyncSession = Depends(get_session),
):
    if actor.role not in {"admin", "platform_staff"}:
        _err("forbidden", "Only admin/platform_staff may view the KYC queue.", 403)
    rows = (await db.execute(
        select(KYCSubmission, User)
        .join(User, User.id == KYCSubmission.user_id)
        .where(KYCSubmission.decision.is_(None))
        .order_by(KYCSubmission.submitted_at.asc())
        .limit(100)
    )).all()
    now = datetime.now(timezone.utc)
    items = []
    for s, u in rows:
        age_hours = int((now - s.submitted_at).total_seconds() // 3600)
        items.append({
            "submission_id":        str(s.id),
            "user_id":              str(u.id),
            "name":                 u.name,
            "phone":                u.phone,
            "submitted_at":         s.submitted_at.isoformat(),
            "age_hours":            age_hours,
            "nid_key":              s.nid_key,
            "trade_license_key":    s.trade_license_key,
            "bank_account_last4":   s.bank_account_last4,
            "mobile_wallet_number": s.mobile_wallet_number,
        })
    return {"items": items, "next_cursor": None}


async def _load_pending_submission(db: AsyncSession, sub_id: str) -> KYCSubmission:
    try:
        sub_uuid = uuid.UUID(sub_id)
    except ValueError:
        _err("validation_error", "submission id is not a UUID", 422)
    sub = (await db.execute(
        select(KYCSubmission).where(KYCSubmission.id == sub_uuid)
    )).scalar_one_or_none()
    if sub is None:
        _err("not_found", "KYC submission not found", 404)
    if sub.decision is not None:
        _err("already_reviewed",
             f"This submission was already {sub.decision!r}.", 409)
    return sub


@router.post(
    "/kyc/{submission_id}/approve", tags=["kyc"],
    operation_id="approveKyc", summary="Approve a KYC submission (admin / platform_staff)",
    responses={**_R_401, **_R_403, **_R_404, **_R_409, **_R_422},
)
async def kyc_approve(
    submission_id: str = Path(
        ...,
        description="KYC submission UUID (from GET /kyc/queue).",
        examples=["11111111-1111-4111-8111-111111111111"],
    ),
    actor: User = Depends(_current_user),
):
    if actor.role not in {"admin", "platform_staff"}:
        _err("forbidden", "Only admin/platform_staff may approve KYC.", 403)
    async with session_scope() as db:
        sub = await _load_pending_submission(db, submission_id)
        u = (await db.execute(
            select(User).where(User.id == sub.user_id)
        )).scalar_one()
        now = datetime.now(timezone.utc)
        sub.decision = "verified"
        sub.reviewed_by = actor.id
        sub.reviewed_at = now
        u.kyc = "verified"
        db.add(Outbox(
            topic=settings.kafka_topic_kyc_approved,
            key=str(u.id),
            payload={
                "event":         "KycApproved",
                "submission_id": str(sub.id),
                "user_id":       str(u.id),
                "decided_at":    now.isoformat(),
                "reviewed_by":   str(actor.id),
            },
        ))
        M.kyc_decision.labels(decision="verified").inc()
    return {
        "submission_id": str(sub.id),
        "user_id":       str(u.id),
        "decision":      "verified",
        "decided_at":    sub.reviewed_at.isoformat(),
    }


@router.post(
    "/kyc/{submission_id}/reject", tags=["kyc"],
    operation_id="rejectKyc", summary="Reject a KYC submission (admin / platform_staff)",
    responses={**_R_401, **_R_403, **_R_404, **_R_409, **_R_422},
)
async def kyc_reject(
    req: KYCRejectReq,
    submission_id: str = Path(
        ...,
        description="KYC submission UUID (from GET /kyc/queue).",
        examples=["11111111-1111-4111-8111-111111111111"],
    ),
    actor: User = Depends(_current_user),
):
    if actor.role not in {"admin", "platform_staff"}:
        _err("forbidden", "Only admin/platform_staff may reject KYC.", 403)
    async with session_scope() as db:
        sub = await _load_pending_submission(db, submission_id)
        u = (await db.execute(
            select(User).where(User.id == sub.user_id)
        )).scalar_one()
        now = datetime.now(timezone.utc)
        sub.decision = "rejected"
        sub.reviewed_by = actor.id
        sub.reviewed_at = now
        sub.rejection_reason = req.reason
        u.kyc = "rejected"
        db.add(Outbox(
            topic=settings.kafka_topic_kyc_rejected,
            key=str(u.id),
            payload={
                "event":            "KycRejected",
                "submission_id":    str(sub.id),
                "user_id":          str(u.id),
                "rejection_reason": req.reason,
                "decided_at":       now.isoformat(),
                "reviewed_by":      str(actor.id),
            },
        ))
        M.kyc_decision.labels(decision="rejected").inc()
    return {
        "submission_id":    str(sub.id),
        "user_id":          str(u.id),
        "decision":         "rejected",
        "rejection_reason": req.reason,
        "decided_at":       sub.reviewed_at.isoformat(),
    }
