"""The three fraud Published-Language events (frozen registry, producer 10, key DID).
Payloads carry canonical IDs only — never PII (R6). Anything else is an R6 violation."""

from __future__ import annotations

import json
from typing import Any

from psycopg import Connection

from fraud import ids

TOPIC_SIGNAL_RAISED = "fraud.enforcement.FraudSignalRaised.v1"
TOPIC_ACCOUNT_HELD = "fraud.enforcement.AccountHeld.v1"
TOPIC_HOLD_RELEASED = "fraud.enforcement.AccountHoldReleased.v1"

PRODUCED_TOPICS = frozenset({TOPIC_SIGNAL_RAISED, TOPIC_ACCOUNT_HELD, TOPIC_HOLD_RELEASED})

CONSUMED_TOPICS = (
    "identity.party.KYCApproved.v1",
    "identity.party.KYCTierChanged.v1",
    "identity.party.PartySuspended.v1",
    "b2c.order.OrderPlaced.v1",
    "b2b.tradeorder.TradeOrderCreated.v1",
)


def _emit(cx: Connection[Any], topic: str, key: str, fields: dict[str, Any], now: int) -> str:
    if topic not in PRODUCED_TOPICS:
        raise ValueError(f"R6 violation: fraud may not produce {topic}")
    event_id = ids.new_event_id()
    payload: dict[str, Any] = {"eventId": event_id, "occurredAt": now, **fields}
    cx.execute(
        "INSERT INTO outbox(event_id, topic, partition_key, payload, occurred_at) "
        "VALUES (%s,%s,%s,%s::jsonb,%s)",
        (event_id, topic, key, json.dumps(payload), now),
    )
    return event_id


def fraud_signal_raised(
    cx: Connection[Any], subject_did: str, reason: str, risk_score: float, now: int
) -> str:
    return _emit(
        cx,
        TOPIC_SIGNAL_RAISED,
        subject_did,
        {"subjectDid": subject_did, "reason": reason, "riskScore": risk_score, "raisedAt": now},
        now,
    )


def account_held(
    cx: Connection[Any], subject_did: str, approver1: str, approver2: str, now: int
) -> str:
    return _emit(
        cx,
        TOPIC_ACCOUNT_HELD,
        subject_did,
        {"subjectDid": subject_did, "approver1": approver1, "approver2": approver2, "heldAt": now},
        now,
    )


def account_hold_released(cx: Connection[Any], subject_did: str, now: int) -> str:
    return _emit(
        cx,
        TOPIC_HOLD_RELEASED,
        subject_did,
        {"subjectDid": subject_did, "releasedAt": now},
        now,
    )
