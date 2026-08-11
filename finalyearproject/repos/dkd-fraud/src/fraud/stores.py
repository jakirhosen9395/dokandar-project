"""Postgres stores: append-only signals, four-eyes pending_holds, spine outbox/inbox,
command idempotency. All writes happen inside a caller-owned transaction (one connection)."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from typing import Any

from psycopg import Connection, errors
from psycopg.rows import tuple_row


@dataclass(frozen=True)
class PendingHold:
    subject_did: str
    reason: str
    approver1: str
    status: str
    approver2: str | None
    requested_at: int
    approved_at: int | None = None


@dataclass(frozen=True)
class StoredResponse:
    request_hash: str
    status: int
    body: dict[str, Any]


@dataclass(frozen=True)
class OutboxRow:
    id: int
    event_id: str
    topic: str
    partition_key: str
    payload: str


def insert_signal(cx: Connection[Any], signal_id: str, subject_did: str, reason: str,
                  risk_score: float, evidence: dict[str, Any] | None, raised_by: str,
                  now: int) -> None:
    cx.execute(
        "INSERT INTO fraud_signals(signal_id, subject_did, reason, risk_score, evidence, "
        "raised_by, raised_at) VALUES (%s,%s,%s,%s,%s::jsonb,%s,%s)",
        (signal_id, subject_did, reason, risk_score,
         json.dumps(evidence) if evidence is not None else None, raised_by, now),
    )


def insert_pending_hold(cx: Connection[Any], subject_did: str, reason: str, approver1: str,
                        evidence: dict[str, Any] | None, now: int) -> bool:
    """One open hold per subject (R4). Returns False when a hold row already exists."""
    try:
        cx.execute(
            "INSERT INTO pending_holds(subject_did, reason, approver1, evidence, status, "
            "requested_at) VALUES (%s,%s,%s,%s::jsonb,'PENDING',%s)",
            (subject_did, reason, approver1,
             json.dumps(evidence) if evidence is not None else None, now),
        )
        return True
    except errors.UniqueViolation:
        return False


_HOLD_COLS = "subject_did, reason, approver1, status, approver2, requested_at, approved_at"


def _hold_row(row: tuple[Any, ...]) -> PendingHold:
    return PendingHold(subject_did=row[0], reason=row[1], approver1=row[2], status=row[3],
                       approver2=row[4], requested_at=row[5], approved_at=row[6])


def lock_hold(cx: Connection[Any], subject_did: str) -> PendingHold | None:
    cur = cx.cursor(row_factory=tuple_row).execute(
        f"SELECT {_HOLD_COLS} FROM pending_holds WHERE subject_did = %s FOR UPDATE",
        (subject_did,),
    )
    row = cur.fetchone()
    return _hold_row(row) if row is not None else None


def get_hold_ro(cx: Connection[Any], subject_did: str) -> PendingHold | None:
    """Plain read — never contends with the four-eyes command locks (reviewer MEDIUM)."""
    cur = cx.cursor(row_factory=tuple_row).execute(
        f"SELECT {_HOLD_COLS} FROM pending_holds WHERE subject_did = %s",
        (subject_did,),
    )
    row = cur.fetchone()
    return _hold_row(row) if row is not None else None


def transition_hold(cx: Connection[Any], subject_did: str, frm: str, to: str,
                    approver2: str | None, now: int) -> bool:
    cur = cx.execute(
        "UPDATE pending_holds SET status = %s, approver2 = COALESCE(%s, approver2), "
        "approved_at = CASE WHEN %s = 'APPROVED' THEN %s ELSE approved_at END, "
        "released_at = CASE WHEN %s = 'RELEASED' THEN %s ELSE released_at END "
        "WHERE subject_did = %s AND status = %s",
        (to, approver2, to, now, to, now, subject_did, frm),
    )
    return cur.rowcount == 1


def delete_hold(cx: Connection[Any], subject_did: str) -> None:
    """A RELEASED hold clears the one-open-hold slot (holds are reversible, R4)."""
    cx.execute("DELETE FROM pending_holds WHERE subject_did = %s AND status = 'RELEASED'",
               (subject_did,))


def inbox_seen(cx: Connection[Any], event_id: str) -> bool:
    cur = cx.execute("SELECT 1 FROM inbox WHERE event_id = %s", (event_id,))
    return cur.fetchone() is not None


def inbox_try_mark(cx: Connection[Any], event_id: str, topic: str, now: int) -> bool:
    cur = cx.execute(
        "INSERT INTO inbox(event_id, topic, processed_at) VALUES (%s,%s,%s) "
        "ON CONFLICT (event_id) DO NOTHING",
        (event_id, topic, now),
    )
    return cur.rowcount == 1


def request_hash(body: dict[str, Any]) -> str:
    return hashlib.sha256(
        json.dumps(body, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def idem_find(cx: Connection[Any], key: str, endpoint: str) -> StoredResponse | None:
    cur = cx.cursor(row_factory=tuple_row).execute(
        "SELECT request_hash, response_status, response_body::text FROM cmd_idempotency "
        "WHERE idem_key = %s AND endpoint = %s",
        (key, endpoint),
    )
    row = cur.fetchone()
    if row is None:
        return None
    return StoredResponse(request_hash=row[0], status=row[1], body=json.loads(row[2]))


def idem_insert(cx: Connection[Any], key: str, endpoint: str, req_hash: str, status: int,
                body: dict[str, Any], now: int) -> None:
    cx.execute(
        "INSERT INTO cmd_idempotency(idem_key, endpoint, request_hash, response_status, "
        "response_body, created_at) VALUES (%s,%s,%s,%s,%s::jsonb,%s)",
        (key, endpoint, req_hash, status, json.dumps(body), now),
    )


def fetch_unpublished(cx: Connection[Any], limit: int) -> list[OutboxRow]:
    cur = cx.cursor(row_factory=tuple_row).execute(
        "SELECT id, event_id, topic, partition_key, payload::text FROM outbox "
        "WHERE published_at IS NULL ORDER BY id LIMIT %s",
        (max(1, min(limit, 500)),),
    )
    return [OutboxRow(id=r[0], event_id=r[1], topic=r[2], partition_key=r[3], payload=r[4])
            for r in cur.fetchall()]


def mark_published(cx: Connection[Any], row_id: int, now: int) -> None:
    cx.execute("UPDATE outbox SET published_at = %s WHERE id = %s", (now, row_id))
