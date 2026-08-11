"""Redis DB 14 — served-feed cache (architecture §3.3).

DEGRADABLE & NON-GATING: a cache miss recomputes from Qdrant/Postgres; a Redis outage
falls straight through to the compute path. Never gates /ready. All ops are best-effort
(return None / no-op on error, never raise).
"""
from __future__ import annotations
import logging
from typing import Optional

from app.config import settings

log = logging.getLogger("reco.redis")

_client = None  # redis.asyncio.Redis | None


async def connect() -> None:
    global _client
    if not settings.redis_host:
        log.info("REDIS_HOST empty — feed cache disabled")
        return
    try:
        import redis.asyncio as aioredis
        _client = aioredis.Redis(
            host=settings.redis_host, port=settings.redis_port,
            password=settings.redis_password or None, db=settings.redis_db,
            socket_connect_timeout=3, socket_timeout=3, decode_responses=True,
        )
        await _client.ping()
        log.info("redis connected db=%d (feed cache)", settings.redis_db)
    except Exception as e:
        log.warning("redis connect deferred (cache degraded): %s", type(e).__name__)
        _client = None


async def health() -> tuple[bool, str]:
    """Diagnostic only — never gates /ready."""
    if _client is None:
        return False, "disabled" if not settings.redis_host else "unreachable"
    try:
        await _client.ping()
        return True, "ok"
    except Exception as e:
        return False, f"err:{type(e).__name__}"


async def get(key: str) -> Optional[str]:
    if _client is None:
        return None
    try:
        return await _client.get(key)
    except Exception:
        return None


async def setex(key: str, value: str, ttl: int) -> None:
    if _client is None:
        return
    try:
        await _client.set(key, value, ex=ttl)
    except Exception:
        pass


async def close() -> None:
    global _client
    if _client is not None:
        try:
            await _client.aclose()
        except Exception:
            pass
    _client = None
