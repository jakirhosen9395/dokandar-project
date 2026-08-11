"""16-recommendation service — feed/similar/cross-sell from PG popularity table.

Qdrant integration is stub (returns popularity-only feed when Qdrant unavailable
or cold-start). Real PyTorch retrain is deferred — interaction_log is the fuel."""
from __future__ import annotations

import json
import logging
import time
import uuid
from datetime import datetime, timezone

from app.config import settings
from app.db.postgres import pool
from app.db import qdrant, redis as redis_cache
from app.observability.metrics import (
    SERVICE_VAL, reco_cache_hit_total, reco_cross_sell_served_total,
    reco_feed_served_total, reco_interactions_ingested_total,
    reco_retrain_total, reco_similar_served_total,
    recommendation_feed_total, recommendation_fallback_total,
    recommendation_retrain_total, recommendation_ann_latency_ms,
)
from app.reco.schemas import CrossSellItem, Feed, FeedItem


log = logging.getLogger("reco.service")


async def get_personal_feed(user_id: str, size: int) -> Feed:
    # 1) Redis DB14 feed cache (degradable — a miss recomputes).
    cache_key = f"reco:feed:{user_id}:{size}"
    cached = await redis_cache.get(cache_key)
    if cached:
        reco_cache_hit_total.labels(SERVICE_VAL).inc()
        try:
            return Feed.model_validate_json(cached)
        except Exception:
            pass  # corrupt cache entry → recompute

    # 2) Qdrant ANN attempt (architecture §4.1). Empty until the off-path retrain populates
    #    embeddings — then it falls through to the popularity feed (degraded, not an error).
    t0 = time.perf_counter()
    vec = await qdrant.get_user_vector(user_id)
    ann = await qdrant.search_products(vec, size) if vec else []
    recommendation_ann_latency_ms.labels(SERVICE_VAL).observe((time.perf_counter() - t0) * 1000)

    if ann:
        items = [FeedItem(product_id=pid, score=sc, reason="personal") for pid, sc in ann]
        source = "personal"
        feed = Feed(source=source, items=items, generated_at=datetime.now(timezone.utc))
    else:
        # 3) Popularity fallback — reranked by the user's interaction history, else cold-start.
        async with pool().acquire() as conn:
            prefs = await conn.fetchval("""
                SELECT array_agg(DISTINCT category_id) FROM interaction_log
                WHERE user_id = $1::uuid AND category_id IS NOT NULL
                  AND occurred_at > now() - interval '90 days' LIMIT 50
            """, user_id)
            if prefs:
                rows = await conn.fetch("""
                    SELECT p.product_id, p.score
                    FROM popularity p
                    WHERE p.product_id NOT IN (
                        SELECT product_id FROM interaction_log
                        WHERE user_id = $1::uuid AND kind IN ('view','order')
                          AND product_id IS NOT NULL
                    )
                    ORDER BY p.score DESC LIMIT $2
                """, user_id, size)
                source = "personal" if rows else "cold_start"
            else:
                rows = await conn.fetch("SELECT product_id, score FROM popularity ORDER BY score DESC LIMIT $1", size)
                source = "cold_start"
        items = [FeedItem(product_id=r["product_id"], score=float(r["score"]), reason=source) for r in rows]
        feed = Feed(source=source, items=items, generated_at=datetime.now(timezone.utc))
        recommendation_fallback_total.labels(SERVICE_VAL).inc()

    reco_feed_served_total.labels(SERVICE_VAL, source).inc()
    recommendation_feed_total.labels(SERVICE_VAL, source).inc()
    # in-request log (trace-correlated) — NO user_id / NO raw feed per §12
    log.info("feed served strategy=%s items=%d", source, len(feed.items))
    await redis_cache.setex(cache_key, feed.model_dump_json(), settings.feed_cache_ttl_seconds)
    return feed


async def get_similar(product_id: str, size: int) -> Feed:
    async with pool().acquire() as conn:
        # Use cross_sell as a proxy for "similar" until Qdrant ANN wired
        rows = await conn.fetch("""
            SELECT paired_product_id AS product_id, weight AS score
            FROM cross_sell WHERE product_id = $1::uuid
            ORDER BY weight DESC LIMIT $2
        """, product_id, size)
        if not rows:
            # Fallback: popularity (same category — would join category)
            rows = await conn.fetch("SELECT product_id, score FROM popularity ORDER BY score DESC LIMIT $1", size)
    items = [FeedItem(product_id=r["product_id"], score=float(r["score"]),
                       reason="similar") for r in rows]
    reco_similar_served_total.labels(SERVICE_VAL).inc()
    return Feed(source="similar", items=items, generated_at=datetime.now(timezone.utc))


async def get_cross_sell(product_id: str, size: int) -> list[CrossSellItem]:
    async with pool().acquire() as conn:
        rows = await conn.fetch("""
            SELECT paired_product_id, weight FROM cross_sell
            WHERE product_id = $1::uuid ORDER BY weight DESC LIMIT $2
        """, product_id, size)
    reco_cross_sell_served_total.labels(SERVICE_VAL).inc()
    return [CrossSellItem(paired_product_id=r["paired_product_id"],
                           weight=float(r["weight"])) for r in rows]


async def ingest_interaction(user_id, kind, product_id=None, shop_id=None,
                              category_id=None, district=None, source_event_id=None):
    async with pool().acquire() as conn:
        # Idempotent projection (§10): a redelivered event (same source_event_id) is a
        # no-op via the UNIQUE partial index → RETURNING tells us if the row was new, so a
        # duplicate does NOT double-bump popularity.
        inserted = await conn.fetchval("""
            INSERT INTO interaction_log (user_id, kind, product_id, shop_id,
                                          category_id, district, source_event_id)
            VALUES ($1::uuid, $2, $3::uuid, $4::uuid, $5::uuid, $6, $7)
            ON CONFLICT (source_event_id) WHERE source_event_id IS NOT NULL DO NOTHING
            RETURNING id
        """, user_id, kind, product_id, shop_id, category_id, district, source_event_id)
        if inserted is None:
            return  # duplicate redelivery — already counted
        # Bump popularity for orders + views + reviews
        if product_id and kind in {"order", "view", "review"}:
            weight = {"order": 5.0, "view": 0.1, "review": 1.0}.get(kind, 0.5)
            await conn.execute("""
                INSERT INTO popularity (product_id, score) VALUES ($1::uuid, $2)
                ON CONFLICT (product_id) DO UPDATE SET
                  score = popularity.score + EXCLUDED.score,
                  updated_at = now()
            """, product_id, weight)
    reco_interactions_ingested_total.labels(SERVICE_VAL, kind).inc()


_retraining_lock = False


async def trigger_retrain() -> dict:
    """Stub — schedules a retrain. Real impl would queue a PyTorch job."""
    global _retraining_lock
    if _retraining_lock:
        reco_retrain_total.labels(SERVICE_VAL, "concurrent_blocked").inc()
        recommendation_retrain_total.labels(SERVICE_VAL, "concurrent_blocked").inc()
        from fastapi import HTTPException, status
        raise HTTPException(status.HTTP_409_CONFLICT, detail={
            "error": {"code": "retrain_in_progress", "message": "another retrain is running"}})
    _retraining_lock = True
    try:
        # Refresh popularity by aggregating last 30 days
        async with pool().acquire() as conn:
            await conn.execute("""
                INSERT INTO popularity (product_id, score)
                SELECT product_id,
                       count(*) FILTER (WHERE kind='order') * 5.0
                       + count(*) FILTER (WHERE kind='review') * 1.0
                       + count(*) FILTER (WHERE kind='view') * 0.1
                FROM interaction_log
                WHERE product_id IS NOT NULL AND occurred_at > now() - interval '30 days'
                GROUP BY product_id
                ON CONFLICT (product_id) DO UPDATE SET
                  score = EXCLUDED.score, updated_at = now()
            """)
            # Refresh cross_sell from co-orders
            await conn.execute("""
                INSERT INTO cross_sell (product_id, paired_product_id, weight)
                SELECT a.product_id, b.product_id, count(*)::double precision
                FROM interaction_log a JOIN interaction_log b
                  ON a.user_id = b.user_id AND a.kind = 'order' AND b.kind = 'order'
                  AND a.product_id != b.product_id
                  AND a.occurred_at > now() - interval '90 days'
                GROUP BY a.product_id, b.product_id
                HAVING count(*) > 1
                ON CONFLICT (product_id, paired_product_id) DO UPDATE SET weight = EXCLUDED.weight
            """)
        reco_retrain_total.labels(SERVICE_VAL, "ok").inc()
        recommendation_retrain_total.labels(SERVICE_VAL, "ok").inc()
        return {"ok": True, "method": "popularity_aggregate"}
    finally:
        _retraining_lock = False
