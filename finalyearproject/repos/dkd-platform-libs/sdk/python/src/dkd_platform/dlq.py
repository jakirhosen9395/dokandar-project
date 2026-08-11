# HAND-AUTHORED platform primitive (NOT dkdgen-generated).
# PL-02 — dead-letter queue with per-aggregate-key park-and-freeze (SA-MSG-09/10).
"""Dead-letter queue: a poison money/custody/inventory event parks ONLY its own aggregate key.

Canonical schema (the SDK standard):

    dlq(id BIGSERIAL PK, event_id TEXT, topic TEXT, key TEXT, payload JSONB, error TEXT,
        parked_at TIMESTAMPTZ default now(), aggregate_key TEXT)

Park-and-freeze (SA-MSG-10): a poison message is quarantined under its `aggregate_key`, never
silently dropped. `is_key_parked` lets a consumer freeze further progress on that single key while
every other key keeps flowing.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

from .dbexec import DbExecutor

_INSERT = (
    'INSERT INTO dlq(event_id, topic, "key", payload, error, aggregate_key, parked_at) '
    "VALUES (%s, %s, %s, %s::jsonb, %s, %s, now())"
)
_SELECT_KEY = "SELECT 1 FROM dlq WHERE aggregate_key = %s LIMIT 1"


def _json_param(payload: Any) -> str:
    if isinstance(payload, str):
        return payload
    return json.dumps(payload, sort_keys=True, separators=(",", ":"))


@dataclass(frozen=True)
class DlqEntry:
    """The park input — `{eventId, topic, key, payload, error, aggregateKey}` in Python casing."""

    event_id: str
    topic: str
    key: str
    payload: Any
    error: str
    aggregate_key: str


class Dlq:
    @staticmethod
    def park(db: DbExecutor, entry: DlqEntry) -> None:
        """Quarantine a poison event under its aggregate key (never drop it)."""
        db.execute(
            _INSERT,
            (
                entry.event_id,
                entry.topic,
                entry.key,
                _json_param(entry.payload),
                entry.error,
                entry.aggregate_key,
            ),
        )

    @staticmethod
    def is_key_parked(db: DbExecutor, aggregate_key: str) -> bool:
        """True when a poison event is frozen on this aggregate key (progress must halt for it)."""
        cur = db.execute(_SELECT_KEY, (aggregate_key,))
        return cur.fetchone() is not None
