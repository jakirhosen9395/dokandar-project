"""Advisory scoring rules. The FR-SCM-020 bands are CANON (verbatim); the velocity threshold
is config-driven policy data (FR-GOV-013). Scores are advisory only — R4: recommend-by-default,
no autonomous enforcement here (the enumerated autonomous set is NEEDS-INFO, so it is empty)."""

from __future__ import annotations

from dataclasses import dataclass

BAND_ALLOW = "ALLOW"
BAND_MONITOR = "ENHANCED_MONITORING"
BAND_HOLD_REVIEW = "HOLD_AND_REVIEW"
BAND_FREEZE_PENDING = "FREEZE_PENDING_INVESTIGATION"

RULE_VELOCITY = "VELOCITY_ANOMALY"


@dataclass(frozen=True)
class Assessment:
    risk_score: float
    band: str
    rule_flags: list[str]
    recommendation: str


def band_for(score: float) -> str:
    """FR-SCM-020 verbatim: <0.40 allow; 0.40–0.70 monitor; 0.70–0.85 hold+review; >0.85 freeze."""
    if score < 0.40:
        return BAND_ALLOW
    if score <= 0.70:
        return BAND_MONITOR
    if score <= 0.85:
        return BAND_HOLD_REVIEW
    return BAND_FREEZE_PENDING


def velocity_score(count: int, threshold: int) -> float:
    """Transparent rule model (modelVersion rule-v1): linear in window count, saturating at 1.0
    when the count doubles the configured threshold. Advisory only (FR-SCM-013..017)."""
    if threshold <= 0:
        raise ValueError("velocity threshold must be > 0")
    if count <= 0:
        return 0.0
    return min(1.0, count / (2.0 * threshold))


def assess(order_count: int, trade_count: int, threshold: int) -> Assessment:
    combined = order_count + trade_count
    score = velocity_score(combined, threshold)
    flags = [RULE_VELOCITY] if combined > threshold else []
    band = band_for(score)
    recommendation = {
        BAND_ALLOW: "no action",
        BAND_MONITOR: "enhanced monitoring",
        BAND_HOLD_REVIEW: "recommend hold + human review (four-eyes)",
        BAND_FREEZE_PENDING: "recommend freeze pending investigation (four-eyes)",
    }[band]
    return Assessment(risk_score=round(score, 4), band=band, rule_flags=flags,
                      recommendation=recommendation)
