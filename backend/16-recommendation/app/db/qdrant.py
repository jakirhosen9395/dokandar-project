"""Qdrant vector store (architecture §3.1) — the ANN embedding store.

DEGRADABLE & NON-GATING (§8.1): Qdrant never gates /ready. The serving path attempts an
ANN lookup and FALLS BACK to the Postgres popularity feed when Qdrant is down/cold or the
user has no embedding yet. Embeddings are populated by the OFF-PATH nightly retrain
(sentence-transformers + PyTorch, Airflow/Ray) — until that runs, every collection is empty
so ANN yields nothing and popularity serves (degraded relevance, not an error).

Every function is best-effort: a Qdrant outage returns None/[] and is logged, never raised.
"""
from __future__ import annotations
import logging
from typing import Optional

from app.config import settings

log = logging.getLogger("reco.qdrant")

# (collection, vector dim) per §3.1.
COLLECTIONS = {
    "user": (settings.qdrant_collection_user, 768),
    "product": (settings.qdrant_collection_product, 768),
    "shop": (settings.qdrant_collection_shop, 256),
}

_client = None  # AsyncQdrantClient | None
_ok = False


async def connect() -> None:
    """Connect + ensure the three collections exist. Non-fatal on failure (degradable)."""
    global _client, _ok
    if not settings.qdrant_url:
        log.info("QDRANT_URL empty — vector store disabled (popularity-only serving)")
        return
    try:
        from qdrant_client import AsyncQdrantClient, models
        _client = AsyncQdrantClient(url=settings.qdrant_url,
                                    api_key=settings.qdrant_api_key or None,
                                    timeout=5)
        for _key, (name, dim) in COLLECTIONS.items():
            try:
                if not await _client.collection_exists(name):
                    await _client.create_collection(
                        collection_name=name,
                        vectors_config=models.VectorParams(size=dim, distance=models.Distance.COSINE),
                    )
                    log.warning("created qdrant collection %s (dim=%d)", name, dim)
            except Exception as e:  # collection ensure is best-effort
                log.warning("qdrant ensure %s failed: %s", name, type(e).__name__)
        _ok = True
        log.info("qdrant connected url=%s", settings.qdrant_url)
    except Exception as e:
        log.warning("qdrant connect failed (degraded → popularity fallback): %s", type(e).__name__)
        _client = None
        _ok = False


async def health() -> tuple[bool, str]:
    """Diagnostic only (§8.2) — never gates /ready."""
    if _client is None:
        return False, "disabled" if not settings.qdrant_url else "unreachable"
    try:
        await _client.get_collections()
        return True, "ok"
    except Exception as e:
        return False, f"err:{type(e).__name__}"


async def get_user_vector(user_id: str) -> Optional[list[float]]:
    """The user's behavioral embedding, or None (cold user / Qdrant down)."""
    if _client is None:
        return None
    try:
        pts = await _client.retrieve(collection_name=settings.qdrant_collection_user,
                                     ids=[user_id], with_vectors=True)
        if pts and pts[0].vector:
            return list(pts[0].vector)
    except Exception as e:
        log.warning("qdrant get_user_vector degraded: %s", type(e).__name__)
    return None


async def search_products(vector: list[float], limit: int) -> list[tuple[str, float]]:
    """ANN over product embeddings → [(product_id, score)]. [] on miss/outage (→ fallback)."""
    if _client is None or not vector:
        return []
    try:
        res = await _client.search(collection_name=settings.qdrant_collection_product,
                                   query_vector=vector, limit=limit)
        return [(str(p.id), float(p.score)) for p in res]
    except Exception as e:
        log.warning("qdrant search degraded (→ popularity): %s", type(e).__name__)
        return []


async def close() -> None:
    global _client, _ok
    if _client is not None:
        try:
            await _client.close()
        except Exception:
            pass
    _client = None
    _ok = False
