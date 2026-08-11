"""FR-SCM-020 band boundaries (canon verbatim) and the transparent velocity rule model."""

import pytest

from fraud import rules


def test_bands_are_canon_verbatim() -> None:
    # Arrange / Act / Assert — <0.40 allow; 0.40-0.70 monitor; 0.70-0.85 hold; >0.85 freeze
    assert rules.band_for(0.0) == rules.BAND_ALLOW
    assert rules.band_for(0.39) == rules.BAND_ALLOW
    assert rules.band_for(0.40) == rules.BAND_MONITOR
    assert rules.band_for(0.70) == rules.BAND_MONITOR
    assert rules.band_for(0.71) == rules.BAND_HOLD_REVIEW
    assert rules.band_for(0.85) == rules.BAND_HOLD_REVIEW
    assert rules.band_for(0.86) == rules.BAND_FREEZE_PENDING
    assert rules.band_for(1.0) == rules.BAND_FREEZE_PENDING


def test_velocity_score_saturates_at_one() -> None:
    assert rules.velocity_score(0, 10) == 0.0
    assert rules.velocity_score(10, 10) == 0.5
    assert rules.velocity_score(20, 10) == 1.0
    assert rules.velocity_score(500, 10) == 1.0


def test_velocity_score_rejects_bad_threshold() -> None:
    with pytest.raises(ValueError):
        rules.velocity_score(1, 0)


def test_assess_flags_velocity_anomaly_above_threshold() -> None:
    quiet = rules.assess(order_count=2, trade_count=1, threshold=10)
    assert quiet.rule_flags == []
    assert quiet.band == rules.BAND_ALLOW

    noisy = rules.assess(order_count=9, trade_count=5, threshold=10)
    assert rules.RULE_VELOCITY in noisy.rule_flags
    assert noisy.risk_score == 0.7
    assert noisy.band == rules.BAND_MONITOR


def test_assess_recommendations_never_autonomous() -> None:
    # R4: even the top band only RECOMMENDS — enforcement needs four-eyes approval.
    hot = rules.assess(order_count=40, trade_count=0, threshold=10)
    assert hot.band == rules.BAND_FREEZE_PENDING
    assert "recommend" in hot.recommendation
