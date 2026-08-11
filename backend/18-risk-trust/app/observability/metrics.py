from __future__ import annotations
from prometheus_client import Counter, Gauge, Histogram

SERVICE_VAL = "18-risk-trust"

risk_scores_total = Counter("risk_scores_total", "Score decisions.", ("service","kind","decision"))
risk_score_ms = Histogram("risk_score_ms", "Score wall-time.", ("service","kind"), buckets=(1,5,10,25,50,100,250,500))
risk_overrides_used_total = Counter("risk_overrides_used_total", "Overrides applied.", ("service","entity_type"))
risk_rules_total = Gauge("risk_rules_total", "Active rules.", ("service",))

# Spec-named metrics (§8.4) — closed-set labels only (decision/degraded); NEVER user_id/score/threshold.
risk_scored_total = Counter("risk_scored_total", "Decisions by outcome.", ("service","decision"))
risk_degraded_total = Counter("risk_degraded_total", "Rule-based fallback served (Scylla/Qdrant/model down).", ("service",))
risk_score_latency_ms = Histogram("risk_score_latency_ms", "Score latency (ms) — the <100ms SLO.", ("service",),
                                   buckets=(1, 5, 10, 25, 50, 100, 250, 500, 1000))
risk_outbox_pending = Gauge("risk_outbox_pending", "Outbox rows awaiting relay.", ("service",))  # MANDATORY (§8.4)
