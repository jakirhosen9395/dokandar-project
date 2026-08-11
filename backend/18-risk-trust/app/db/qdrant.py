"""Qdrant — graph-embedding ANN store (§3.2). NON-GATING & degradable: the synchronous
score path is rule-based (velocity/device/geo over Postgres) and the precomputed graph
embeddings are an OFF-PATH enhancement (built by the nightly retrain). When Qdrant is
absent/down the score is pure rule-based — a degraded but valid serve (risk_degraded_total).
Never gates /ready (risk sits on the checkout hot path — a vector blip must not cascade)."""
from __future__ import annotations
import logging
from app.config import settings

log = logging.getLogger("risk.qdrant")
_client = None
_ok = False


async def connect() -> None:
    global _client, _ok
    if not settings.qdrant_url:
        log.info("QDRANT_URL empty — graph ANN disabled (rule-based scoring)")
        return
    try:
        from qdrant_client import AsyncQdrantClient, models
        _client = AsyncQdrantClient(url=settings.qdrant_url, api_key=settings.qdrant_api_key or None, timeout=5)
        name = settings.qdrant_collection
        try:
            if not await _client.collection_exists(name):
                await _client.create_collection(
                    collection_name=name,
                    vectors_config=models.VectorParams(size=128, distance=models.Distance.COSINE))
                log.warning("created qdrant collection %s", name)
        except Exception as e:
            log.warning("qdrant ensure %s failed: %s", name, type(e).__name__)
        _ok = True
        log.info("qdrant connected url=%s", settings.qdrant_url)
    except Exception as e:
        log.warning("qdrant connect failed (degraded → rule-based): %s", type(e).__name__)
        _client = None
        _ok = False


def is_up() -> bool:
    return _ok


async def health() -> tuple[bool, str]:
    if _client is None:
        return False, "disabled" if not settings.qdrant_url else "unreachable"
    try:
        await _client.get_collections()
        return True, "ok"
    except Exception as e:
        return False, f"err:{type(e).__name__}"


async def close() -> None:
    global _client, _ok
    if _client is not None:
        try:
            await _client.close()
        except Exception:
            pass
    _client = None
    _ok = False
