"""Advisory computations (pure, unit-tested). Every output carries the FR-ANL-051 envelope
(advisory=true, confidence, model_id, generated_ts, expires_ts); the shortage rule is the
CANON FR-ANL-012 default: shortage when projected supply < demand * 1.15."""

from __future__ import annotations

import time
from typing import Any

from analytics.config import SHORTAGE_SAFETY_FACTOR

MODEL_ID = "rule-v1"
ADVISORY_TTL_MS = 15 * 60 * 1000  # freshness Tier-2 <15min best-effort (SA §15.2)

CLASS_WATCH = "WATCH"
CLASS_WARN = "WARN"
CLASS_CRITICAL = "CRITICAL"


def now_ms() -> int:
    return int(time.time() * 1000)


def envelope(payload: dict[str, Any], confidence: str,
             generated_ts: int | None = None) -> dict[str, Any]:
    ts = generated_ts if generated_ts is not None else now_ms()
    return {
        **payload,
        "advisory": True,
        "confidence": confidence,
        "model_id": MODEL_ID,
        "generated_ts": ts,
        "expires_ts": ts + ADVISORY_TTL_MS,
    }


def shortage_class(supply: int, demand: int) -> str | None:
    """FR-ANL-012: shortage when projected supply < demand * 1.15 (canon default factor).
    Sub-bands within the shortage region are transparent rule policy (rule-v1):
    CRITICAL when supply < demand, WARN when supply < demand*1.05, else WATCH."""
    if demand <= 0:
        return None
    if supply >= demand * SHORTAGE_SAFETY_FACTOR:
        return None
    if supply < demand:
        return CLASS_CRITICAL
    if supply < demand * 1.05:
        return CLASS_WARN
    return CLASS_WATCH


def price_hint(prices: list[tuple[int, int]]) -> dict[str, Any] | None:
    """Non-binding price hint (FR-ANL-042): median of recent agreed unit prices.
    prices = [(occurred_at, unit_price_poisha), ...] — integer poisha only."""
    if not prices:
        return None
    values = sorted(v for _, v in prices if v > 0)
    if not values:
        return None
    n = len(values)
    median = values[n // 2] if n % 2 == 1 else (values[n // 2 - 1] + values[n // 2]) // 2
    return {
        "medianUnitPricePoisha": median,
        "sampleSize": n,
        "minPoisha": values[0],
        "maxPoisha": values[-1],
    }


def forecast(daily_counts: list[int]) -> dict[str, Any]:
    """Naive P10/P50/P90 demand forecast from a daily-count history (FR-ANL-010 horizons are
    canon; the estimator is transparent rule-v1: empirical quantiles of the observed window)."""
    if not daily_counts:
        return {"p10": 0, "p50": 0, "p90": 0, "observedDays": 0}
    s = sorted(daily_counts)
    n = len(s)

    def q(f: float) -> int:
        return s[min(n - 1, int(f * n))]

    # P50 = true median (even-n averages the middle pair, reviewer MEDIUM)
    p50 = s[n // 2] if n % 2 == 1 else (s[n // 2 - 1] + s[n // 2]) // 2
    return {"p10": q(0.10), "p50": p50, "p90": q(0.90), "observedDays": n}


def confidence_for(sample: int) -> str:
    """FR-ANL-018 labels; band edges are transparent rule policy (small-sample honesty)."""
    if sample >= 30:
        return "HIGH"
    if sample >= 10:
        return "MEDIUM"
    return "LOW_CONFIDENCE"
