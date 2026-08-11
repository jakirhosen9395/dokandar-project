"""R6 conformance: only the three registered fraud topics may be produced; payloads carry
the envelope (eventId/occurredAt) and canonical IDs only."""

import json
from typing import Any

import pytest

from fraud import events


class FakeCx:
    def __init__(self) -> None:
        self.calls: list[tuple[str, tuple[Any, ...]]] = []

    def execute(self, sql: str, params: tuple[Any, ...]) -> None:
        self.calls.append((sql, params))


def test_producer_guard_rejects_foreign_topics() -> None:
    cx = FakeCx()
    with pytest.raises(ValueError, match="R6"):
        events._emit(cx, "custody.passport.CustodyTransferred.v1", "k", {}, 1)  # type: ignore[arg-type]
    assert cx.calls == []


def test_account_held_payload_matches_registry() -> None:
    cx = FakeCx()
    event_id = events.account_held(cx, "did:dokandar:x", "did:dokandar:a1", "did:dokandar:a2", 999)  # type: ignore[arg-type]
    sql, params = cx.calls[0]
    assert "INSERT INTO outbox" in sql
    assert params[1] == events.TOPIC_ACCOUNT_HELD
    assert params[2] == "did:dokandar:x"  # partition key = DID (registry ordering key)
    payload = json.loads(params[3])
    assert payload["eventId"] == event_id
    assert payload["occurredAt"] == 999
    assert payload["approver1"] == "did:dokandar:a1"
    assert payload["approver2"] == "did:dokandar:a2"
    assert payload["heldAt"] == 999


def test_signal_and_release_payloads() -> None:
    cx = FakeCx()
    events.fraud_signal_raised(cx, "did:dokandar:x", "VELOCITY_ANOMALY", 0.72, 5)  # type: ignore[arg-type]
    events.account_hold_released(cx, "did:dokandar:x", 7)  # type: ignore[arg-type]
    signal = json.loads(cx.calls[0][1][3])
    release = json.loads(cx.calls[1][1][3])
    assert signal["riskScore"] == 0.72 and signal["raisedAt"] == 5
    assert release["releasedAt"] == 7
