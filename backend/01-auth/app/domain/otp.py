"""OTP in Redis: hashed code with TTL, per-phone rate limit, attempt counter."""
from __future__ import annotations
import secrets
from typing import Optional
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError
import redis.asyncio as redis
from app.config import settings
from app.observability import metrics as M


_hasher = PasswordHasher()
_redis: Optional[redis.Redis] = None


def get_redis() -> redis.Redis:
    global _redis
    if _redis is None:
        _redis = redis.from_url(settings.redis_url, decode_responses=True)
    return _redis


def _gen_code() -> str:
    return f"{secrets.randbelow(1_000_000):06d}"


async def request_otp(phone: str, purpose: str) -> str:
    """Generate, store hashed, return raw code (caller hands to SMS worker)."""
    r = get_redis()
    # rate limit per phone
    rate_key = f"otp_rate:{phone}"
    used = await r.incr(rate_key)
    if used == 1:
        await r.expire(rate_key, 3600)
    if used > settings.otp_rate_per_hour:
        raise PermissionError("rate_limited")
    code = _gen_code()
    h = _hasher.hash(code)
    await r.setex(f"otp:{purpose}:{phone}", settings.otp_ttl_seconds, f"{h}|0")
    M.otp_requests.labels(purpose=purpose).inc()
    return code


async def verify_otp(phone: str, purpose: str, code: str) -> bool:
    r = get_redis()
    key = f"otp:{purpose}:{phone}"
    raw = await r.get(key)
    if not raw:
        M.otp_verify.labels(purpose=purpose, result="expired").inc()
        return False
    h, attempts = raw.rsplit("|", 1)
    attempts_i = int(attempts)
    if attempts_i >= settings.otp_max_attempts:
        await r.delete(key)
        M.otp_verify.labels(purpose=purpose, result="exhausted").inc()
        raise PermissionError("otp_max_attempts")
    try:
        _hasher.verify(h, code)
    except VerifyMismatchError:
        await r.set(key, f"{h}|{attempts_i + 1}", keepttl=True)
        M.otp_verify.labels(purpose=purpose, result="invalid").inc()
        return False
    # success — burn the code so it cannot be reused
    await r.delete(key)
    M.otp_verify.labels(purpose=purpose, result="ok").inc()
    return True
