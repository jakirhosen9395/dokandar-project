"""FR-ANL-012 shortage rule (canon 1.15 factor), FR-ANL-051 envelope, hint/forecast math."""

from analytics import advisory


def test_shortage_uses_canon_safety_factor() -> None:
    # supply >= demand * 1.15 -> no shortage
    assert advisory.shortage_class(supply=115, demand=100) is None
    assert advisory.shortage_class(supply=114, demand=100) == advisory.CLASS_WATCH
    assert advisory.shortage_class(supply=104, demand=100) == advisory.CLASS_WARN
    assert advisory.shortage_class(supply=99, demand=100) == advisory.CLASS_CRITICAL
    assert advisory.shortage_class(supply=10, demand=0) is None


def test_envelope_carries_fr_anl_051_fields() -> None:
    e = advisory.envelope({"x": 1}, "MEDIUM", generated_ts=1000)
    assert e["advisory"] is True
    assert e["confidence"] == "MEDIUM"
    assert e["model_id"] == "rule-v1"
    assert e["generated_ts"] == 1000
    assert e["expires_ts"] == 1000 + advisory.ADVISORY_TTL_MS


def test_price_hint_median_is_integer_poisha() -> None:
    hint = advisory.price_hint([(1, 2000), (2, 2500), (3, 1500)])
    assert hint is not None
    assert hint["medianUnitPricePoisha"] == 2000
    assert hint["sampleSize"] == 3
    even = advisory.price_hint([(1, 1000), (2, 2001)])
    assert even is not None
    assert even["medianUnitPricePoisha"] == 1500  # integer floor division, never float


def test_price_hint_empty_and_zero_prices() -> None:
    assert advisory.price_hint([]) is None
    assert advisory.price_hint([(1, 0)]) is None


def test_forecast_quantiles() -> None:
    fc = advisory.forecast([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    assert fc["p10"] == 2
    assert fc["p50"] == 5  # true even-n median: (5+6)//2
    assert fc["p90"] == 10
    assert fc["observedDays"] == 10
    assert advisory.forecast([]) == {"p10": 0, "p50": 0, "p90": 0, "observedDays": 0}


def test_confidence_labels() -> None:
    assert advisory.confidence_for(3) == "LOW_CONFIDENCE"
    assert advisory.confidence_for(15) == "MEDIUM"
    assert advisory.confidence_for(50) == "HIGH"
