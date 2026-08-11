# HAND-AUTHORED platform primitive (NOT dkdgen-generated).
# PL-02 — transactional outbox + publisher relay (SA-CONV-QUARTET, EF §21.1 / EF-EVT-6).
"""Transactional outbox: the event row is inserted with the aggregate write, in the caller's tx.

Canonical schema (the SDK standard, already live in dkd-custody-ledger):

    outbox(id BIGSERIAL PK, event_id TEXT NOT NULL UNIQUE, topic TEXT, key TEXT, payload JSONB,
           occurred_at_ms BIGINT, created_at TIMESTAMPTZ default now(), published_at TIMESTAMPTZ NULL)
    CREATE INDEX outbox_unpublished_idx ON outbox (id) WHERE published_at IS NULL;

`enqueue` is idempotent on `event_id` (ON CONFLICT DO NOTHING) so a retried command never
double-emits. `OutboxRelay` drains unpublished rows in id order and stamps `published_at`; it
injects the `traceparent` (stub-safe: pass through when absent), `event_id` and `producer_context`
headers the fleet R6 convention requires.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

from .dbexec import DbExecutor

# `key` is a non-reserved word in Postgres but reads as a keyword — always quote it.
_INSERT = (
    'INSERT INTO outbox(event_id, topic, "key", payload, occurred_at_ms) '
    "VALUES (%s, %s, %s, %s::jsonb, %s) "
    "ON CONFLICT (event_id) DO NOTHING"
)
_SELECT_UNPUBLISHED = (
    'SELECT id, event_id, topic, "key", payload::text, occurred_at_ms FROM outbox '
    "WHERE published_at IS NULL ORDER BY id LIMIT %s"
)
_MARK_PUBLISHED = "UPDATE outbox SET published_at = now() WHERE id = ANY(%s)"

_MAX_BATCH = 500


def _json_param(payload: Any) -> str:
    """JSONB bind value. Dicts/lists are canonicalised; a pre-serialized str passes through."""
    if isinstance(payload, str):
        return payload
    return json.dumps(payload, sort_keys=True, separators=(",", ":"))


@dataclass(frozen=True)
class OutboxRecord:
    """The enqueue input — `{eventId, topic, key, payload, occurredAtMs}` in Python casing."""

    event_id: str
    topic: str
    key: str
    payload: Any
    occurred_at_ms: int


@dataclass(frozen=True)
class UnpublishedRow:
    id: int
    event_id: str
    topic: str
    key: str
    payload: str
    occurred_at_ms: int


class Outbox:
    """Write side — called inside the aggregate's transaction."""

    @staticmethod
    def enqueue(tx: DbExecutor, record: OutboxRecord) -> bool:
        """Insert one outbox row atomically with the caller's aggregate write.

        Returns True when the row was inserted, False when `event_id` already existed
        (ON CONFLICT DO NOTHING — a duplicate command is a silent no-op, never a double-emit).
        """
        cur = tx.execute(
            _INSERT,
            (
                record.event_id,
                record.topic,
                record.key,
                _json_param(record.payload),
                record.occurred_at_ms,
            ),
        )
        return cur.rowcount == 1


class OutboxRelay:
    """Publisher-loop side — reads unpublished rows and marks them published."""

    @staticmethod
    def fetch_unpublished(db: DbExecutor, limit: int) -> list[UnpublishedRow]:
        cur = db.execute(_SELECT_UNPUBLISHED, (max(1, min(limit, _MAX_BATCH)),))
        return [
            UnpublishedRow(
                id=r[0], event_id=r[1], topic=r[2], key=r[3], payload=r[4], occurred_at_ms=r[5]
            )
            for r in cur.fetchall()
        ]

    @staticmethod
    def mark_published(db: DbExecutor, ids: list[int]) -> int:
        if not ids:
            return 0
        cur = db.execute(_MARK_PUBLISHED, (list(ids),))
        return cur.rowcount

    @staticmethod
    def headers(
        row: UnpublishedRow, producer_context: str, traceparent: str | None = None
    ) -> list[tuple[str, bytes]]:
        """Kafka headers for a published row. `event_id` + `producer_context` are always present;
        `traceparent` is passed through only when the caller carries one (stub-safe when None)."""
        hdrs = [
            ("event_id", row.event_id.encode()),
            ("producer_context", producer_context.encode()),
        ]
        if traceparent:
            hdrs.append(("traceparent", traceparent.encode()))
        return hdrs
