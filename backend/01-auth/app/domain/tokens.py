"""JWT (RS256) access/refresh issuance + verification + rotation."""
from __future__ import annotations
import base64
import hashlib
import secrets
import uuid
from datetime import datetime, timedelta, timezone
from typing import Optional, Tuple
import jwt
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession
from app.config import settings
from app.db.models import RefreshToken, User
from app.db.session import SessionLocal
from app.observability import metrics as M


def _decode_b64(b64: str) -> bytes:
    if not b64:
        raise RuntimeError("JWT key not configured (JWT_*_KEY_B64 missing)")
    return base64.b64decode(b64.encode())


def _private_pem() -> bytes:
    return _decode_b64(settings.jwt_private_key_b64)


def _public_pem() -> bytes:
    return _decode_b64(settings.jwt_public_key_b64)


def public_jwks() -> dict:
    """RFC 7517 JWKS for /jwks."""
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.rsa import RSAPublicKey
    pub = serialization.load_pem_public_key(_public_pem())
    assert isinstance(pub, RSAPublicKey)
    nums = pub.public_numbers()
    def b64uint(i: int) -> str:
        b = i.to_bytes((i.bit_length() + 7) // 8, "big")
        return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
    kid = hashlib.sha256(_public_pem()).hexdigest()[:16]
    return {"keys": [{
        "kty": "RSA", "kid": kid, "use": "sig", "alg": "RS256",
        "n": b64uint(nums.n), "e": b64uint(nums.e),
    }]}


def issue_access_token(user: User) -> Tuple[str, str]:
    """Returns (jwt, jti)."""
    now = datetime.now(timezone.utc)
    jti = str(uuid.uuid4())
    claims = {
        "sub": str(user.id),
        "role": user.role,
        "phone": user.phone,
        "lang": user.lang,
        "kyc": user.kyc,
        "iss": settings.jwt_issuer,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(seconds=settings.jwt_access_ttl_seconds)).timestamp()),
        "jti": jti,
    }
    token = jwt.encode(claims, _private_pem(), algorithm="RS256")
    M.tokens_issued.labels(type="access", role=user.role).inc()
    return token, jti


def verify_access_token(token: str) -> dict:
    """Raises jwt.PyJWTError on invalid. Returns claims dict."""
    return jwt.decode(
        token, _public_pem(),
        algorithms=["RS256"],
        issuer=settings.jwt_issuer,
        options={"require": ["exp", "iat", "sub"]},
    )


def _hash_refresh(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


async def issue_refresh_token(
    db: AsyncSession, user: User,
    family_id: Optional[uuid.UUID] = None,
    user_agent: str | None = None, ip: str | None = None,
) -> str:
    raw = secrets.token_urlsafe(48)
    rt = RefreshToken(
        user_id=user.id,
        token_hash=_hash_refresh(raw),
        family_id=family_id or uuid.uuid4(),
        expires_at=datetime.now(timezone.utc) + timedelta(seconds=settings.jwt_refresh_ttl_seconds),
        user_agent=user_agent, ip=ip,
    )
    db.add(rt)
    await db.flush()
    M.tokens_issued.labels(type="refresh", role=user.role).inc()
    return raw


async def rotate_refresh_token(
    db: AsyncSession, raw_token: str,
    user_agent: str | None = None, ip: str | None = None,
) -> Tuple[User, str, str]:
    """Rotate. Returns (user, new_refresh, new_access). On reuse → revoke family + raise."""
    h = _hash_refresh(raw_token)
    rt = (await db.execute(
        select(RefreshToken).where(RefreshToken.token_hash == h)
    )).scalar_one_or_none()
    if rt is None:
        raise PermissionError("refresh_invalid")
    if rt.expires_at <= datetime.now(timezone.utc):
        raise PermissionError("refresh_invalid")
    if rt.revoked_at is not None:
        # Reuse detected — revoke the WHOLE family. This MUST be persisted in a
        # SEPARATE, independently-committed session: the caller invokes us inside
        # session_scope(), which rolls back when we raise PermissionError below.
        # If we revoked on `db` and then raised, that rollback would silently undo
        # the lockdown and the sibling (still-active) token would keep working —
        # defeating the spec (§7: "replay → entire family revoked"). Committing in
        # its own session makes the family revocation durable regardless of the
        # caller's rollback.
        async with SessionLocal() as revoke_session:
            await revoke_session.execute(
                update(RefreshToken)
                .where(RefreshToken.family_id == rt.family_id)
                .where(RefreshToken.revoked_at.is_(None))
                .values(revoked_at=datetime.now(timezone.utc))
            )
            await revoke_session.commit()
        M.refresh_reuse_detected.inc()
        raise PermissionError("refresh_reuse_detected")
    # mark this one revoked, issue a new one in the same family
    rt.revoked_at = datetime.now(timezone.utc)
    user = (await db.execute(
        select(User).where(User.id == rt.user_id)
    )).scalar_one()
    new_raw = await issue_refresh_token(db, user, family_id=rt.family_id, user_agent=user_agent, ip=ip)
    access, _ = issue_access_token(user)
    return user, new_raw, access


async def revoke_refresh_token(db: AsyncSession, raw_token: str) -> None:
    """Idempotent: already-revoked → still 204."""
    h = _hash_refresh(raw_token)
    rt = (await db.execute(
        select(RefreshToken).where(RefreshToken.token_hash == h)
    )).scalar_one_or_none()
    if rt is None or rt.revoked_at is not None:
        return
    rt.revoked_at = datetime.now(timezone.utc)
