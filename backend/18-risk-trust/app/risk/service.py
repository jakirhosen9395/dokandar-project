"""18-risk-trust service — rule engine over PG (fallback when Scylla/Qdrant absent)."""
from __future__ import annotations

import json
import logging
import time
import uuid
from datetime import datetime, timezone

from app.config import settings
from app.db.postgres import pool
from app.db import qdrant
from app.observability.metrics import (
    SERVICE_VAL, risk_overrides_used_total, risk_score_ms, risk_scores_total,
    risk_scored_total, risk_degraded_total, risk_score_latency_ms,
)
from app.risk.schemas import (
    OverrideBody, RuleBody, ScoreCheckoutBody, ScoreCODBody, ScoreResponse, ScoreReviewBody,
)


log = logging.getLogger("risk.service")


async def _check_override(conn, entity_type: str, entity_id) -> dict | None:
    row = await conn.fetchrow("""
        SELECT action, reason FROM risk_overrides
        WHERE entity_type = $1 AND entity_id = $2::uuid
          AND (expires_at IS NULL OR expires_at > now())
        ORDER BY created_at DESC LIMIT 1
    """, entity_type, entity_id)
    if row:
        risk_overrides_used_total.labels(SERVICE_VAL, entity_type).inc()
        return {"action": row["action"], "reason": row["reason"]}
    return None


async def score_checkout(body: ScoreCheckoutBody) -> ScoreResponse:
    t0 = time.perf_counter()
    reasons: list[str] = []
    score = 0.0
    decision = "allow"
    async with pool().acquire() as conn:
        # 1. Override fence
        ov = await _check_override(conn, "user", body.user_id) or await _check_override(conn, "order", body.order_id)
        if ov:
            await _persist_decision(conn, "checkout", body.order_id, ov["action"], 1.0, [f"override:{ov['reason']}"])
            _record_metrics("checkout", ov["action"], t0)
            return ScoreResponse(decision=ov["action"], reason_codes=[f"override:{ov['reason']}"])

        # 2. Velocity (orders in 1h)
        vel = await conn.fetchval("""
            SELECT count(*) FROM risk_decisions
            WHERE entity_type = 'checkout' AND scored_at > now() - interval '1 hour'
              AND entity_id IN (
                SELECT entity_id FROM risk_decisions WHERE entity_type='checkout'
                GROUP BY entity_id
              )
        """)
        # simpler velocity proxy via cod_refusals + decisions count for this user — naive but works
        recent = await conn.fetchval("""
            SELECT count(*) FROM risk_decisions
            WHERE entity_type='checkout' AND scored_at > now() - interval '1 hour'
        """)
        if recent and recent > 10:
            reasons.append("velocity_high")
            score += 0.3

        # 3. High amount — > 50,000 BDT = 5M minor
        if body.amount_minor > 5_000_000:
            reasons.append("amount_high")
            score += 0.2

        # 4. COD-specific signal
        if body.payment_method == "cod":
            cod_score, cod_reasons = await _cod_signal(conn, body.user_id)
            score += cod_score
            reasons.extend(cod_reasons)

        # 5. Decide
        if score >= 0.7: decision = "deny"
        elif score >= 0.3: decision = "review"
        else: decision = "allow"

        await _persist_decision(conn, "checkout", body.order_id, decision, score, reasons)

    _record_metrics("checkout", decision, t0)
    return ScoreResponse(decision=decision, reason_codes=reasons)


async def _cod_signal(conn, user_id) -> tuple[float, list[str]]:
    refusals = await conn.fetchval(
        "SELECT count(*) FROM cod_refusals WHERE user_id = $1::uuid",
        user_id,
    ) or 0
    if refusals >= 3:
        return 0.6, ["cod_refusal_history"]
    if refusals >= 1:
        return 0.2, ["cod_prior_refusal"]
    return 0.0, []


async def score_cod(body: ScoreCODBody) -> ScoreResponse:
    t0 = time.perf_counter()
    reasons: list[str] = []
    score = 0.0
    async with pool().acquire() as conn:
        cod_score, cod_reasons = await _cod_signal(conn, body.user_id)
        score += cod_score; reasons.extend(cod_reasons)
        if body.amount_minor > 2_000_000:  # > 20,000 BDT COD
            score += 0.2; reasons.append("cod_amount_high")
        if score >= 0.7: decision = "deny"
        elif score >= 0.3: decision = "review"
        else: decision = "allow"
        await _persist_decision(conn, "cod_order", body.order_id, decision, score, reasons)
    _record_metrics("cod", decision, t0)
    return ScoreResponse(decision=decision, reason_codes=reasons)


async def score_review(body: ScoreReviewBody) -> ScoreResponse:
    t0 = time.perf_counter()
    reasons: list[str] = []
    score = 0.0
    # naive content-heuristic
    text_lower = body.body.lower()
    spam_signals = ["http://", "https://", "click here", "buy now", "free money"]
    matches = sum(1 for s in spam_signals if s in text_lower)
    if matches:
        score += min(0.4 * matches, 0.8)
        reasons.append(f"spam_keywords:{matches}")
    if len(body.body) > 5000:
        score += 0.2; reasons.append("text_long")
    decision = "deny" if score >= 0.7 else ("review" if score >= 0.3 else "allow")
    async with pool().acquire() as conn:
        await _persist_decision(conn, "review", body.review_id, decision, score, reasons)
    _record_metrics("review", decision, t0)
    return ScoreResponse(decision=decision, reason_codes=reasons)


async def _persist_decision(conn, entity_type: str, entity_id, decision: str, score: float, reasons: list[str]) -> None:
    # Persist the decision (score kept internal) AND enqueue the risk.decision event in the
    # SAME tx (transactional outbox, §10). The relay drains outbox → dokandar.risk.decision.
    # The OUTBOX PAYLOAD carries the decision + opaque reason_codes only — NEVER the score.
    await conn.execute("""
        INSERT INTO risk_decisions (entity_type, entity_id, decision, score, reason_codes, scored_at)
        VALUES ($1, $2::uuid, $3, $4, $5::text[], now())
        ON CONFLICT (entity_type, entity_id) DO UPDATE SET
          decision = EXCLUDED.decision, score = EXCLUDED.score,
          reason_codes = EXCLUDED.reason_codes, scored_at = now()
    """, entity_type, entity_id, decision, score, reasons)
    await conn.execute("""
        INSERT INTO outbox (topic, key, payload)
        VALUES ($1, $2, $3::jsonb)
    """, settings.kafka_topic_risk_decision, str(entity_id),
         json.dumps({"event": "risk.decision", "entity_type": entity_type,
                     "entity_id": str(entity_id), "decision": decision, "reason_codes": reasons}))


def _record_metrics(kind: str, decision: str, t0: float) -> None:
    risk_scores_total.labels(SERVICE_VAL, kind, decision).inc()
    risk_scored_total.labels(SERVICE_VAL, decision).inc()
    ms = (time.perf_counter() - t0) * 1000
    risk_score_ms.labels(SERVICE_VAL, kind).observe(ms)
    risk_score_latency_ms.labels(SERVICE_VAL).observe(ms)
    # The ML/ANN graph signal isn't on the synchronous path (it's precomputed/off-path) —
    # when Qdrant is unavailable the score is pure rule-based: a degraded (but valid) serve.
    if not qdrant.is_up():
        risk_degraded_total.labels(SERVICE_VAL).inc()


# ── Rules + overrides admin ────────────────────────────────────────────────


async def list_rules() -> list[dict]:
    async with pool().acquire() as conn:
        rows = await conn.fetch("SELECT * FROM risk_rules ORDER BY created_at DESC")
    return [dict(r) for r in rows]


async def create_rule(user: dict, body: RuleBody) -> dict:
    async with pool().acquire() as conn:
        row = await conn.fetchrow("""
            INSERT INTO risk_rules (name, signal, threshold, action, active, created_by)
            VALUES ($1, $2, $3::jsonb, $4, $5, $6::uuid) RETURNING *
        """, body.name, body.signal, json.dumps(body.threshold),
             body.action, body.active, user["sub"])
    return dict(row)


async def create_override(user: dict, body: OverrideBody) -> dict:
    async with pool().acquire() as conn:
        row = await conn.fetchrow("""
            INSERT INTO risk_overrides (entity_type, entity_id, action, reason, expires_at, created_by)
            VALUES ($1, $2::uuid, $3, $4, $5::timestamptz, $6::uuid) RETURNING *
        """, body.entity_type, body.entity_id, body.action, body.reason,
             body.expires_at, user["sub"])
    return dict(row)


async def record_cod_refusal(user_id: str, order_id: str) -> None:
    """Called by Kafka shipment.failed_delivery consumer."""
    async with pool().acquire() as conn:
        await conn.execute(
            "INSERT INTO cod_refusals (user_id, order_id) VALUES ($1::uuid, $2::uuid)",
            user_id, order_id,
        )
