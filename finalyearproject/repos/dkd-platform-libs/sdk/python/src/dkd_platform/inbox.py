# HAND-AUTHORED platform primitive (NOT dkdgen-generated).
# PL-02 — consumer inbox dedup (SA-CONV-QUARTET, EF §21.1 / EF-EVT-6).
"""Consumer inbox: effectively-once delivery via per-(consumer, event_id) dedup.

Canonical schema (the SDK standard):

    inbox(consumer TEXT, event_id TEXT, processed_at TIMESTAMPTZ, PRIMARY KEY (consumer, event_id))

`already_processed` and `mark_processed` MUST run in the SAME transaction as the side effect they
guard, so a crash mid-handler replays harmlessly and a committed effect is never re-applied.
"""
from __future__ import annotations

from .dbexec import DbExecutor

_SELECT = "SELECT 1 FROM inbox WHERE consumer = %s AND event_id = %s"
_INSERT = (
    "INSERT INTO inbox(consumer, event_id, processed_at) VALUES (%s, %s, now()) "
    "ON CONFLICT (consumer, event_id) DO NOTHING"
)


class Inbox:
    @staticmethod
    def already_processed(tx: DbExecutor, consumer: str, event_id: str) -> bool:
        """True when this consumer has already processed `event_id` (a duplicate delivery)."""
        cur = tx.execute(_SELECT, (consumer, event_id))
        return cur.fetchone() is not None

    @staticmethod
    def mark_processed(tx: DbExecutor, consumer: str, event_id: str) -> bool:
        """Record the event as processed. Returns True when newly marked, False if a concurrent
        delivery won the race (ON CONFLICT DO NOTHING) — either way the effect runs exactly once."""
        cur = tx.execute(_INSERT, (consumer, event_id))
        return cur.rowcount == 1
