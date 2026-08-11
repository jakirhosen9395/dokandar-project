"""asyncpg pool — coupon uses raw SQL (CHECK constraints + jsonb outbox)."""
from __future__ import annotations

import logging

import asyncpg

from app.config import settings


log = logging.getLogger("reporting.db")

_pool: asyncpg.Pool | None = None


async def connect() -> asyncpg.Pool:
    global _pool
    if _pool is not None:
        return _pool
    _pool = await asyncpg.create_pool(
        dsn=settings.postgres_dsn,
        min_size=2,
        max_size=10,
        command_timeout=10,
        server_settings={"application_name": "07-coupon"},
    )
    async with _pool.acquire() as conn:
        await conn.fetchval("SELECT 1")
    log.info("postgres connected db=%s", settings.postgres_db)
    return _pool


async def disconnect() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
    _pool = None


def pool() -> asyncpg.Pool:
    if _pool is None:
        raise RuntimeError("postgres pool not connected — call db.postgres.connect() first")
    return _pool
