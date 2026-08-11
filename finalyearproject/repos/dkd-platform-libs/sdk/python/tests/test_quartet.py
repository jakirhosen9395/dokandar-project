"""PL-02 conformance — outbox/inbox/DLQ quartet against an in-memory fake DbExecutor.

The fake implements the driver-agnostic `dbexec.DbExecutor` surface: it records every (sql, params)
issued AND models enough table state (unique event_id, composite inbox PK, dlq rows) to prove the
effectively-once + park-and-freeze semantics without a live Postgres.
"""
from __future__ import annotations

from typing import Any, Sequence

from dkd_platform import dlq, inbox, outbox
from dkd_platform.dlq import DlqEntry
from dkd_platform.outbox import OutboxRecord


class _Cursor:
    def __init__(self, rowcount: int, rows: list[tuple[Any, ...]]):
        self._rowcount = rowcount
        self._rows = rows

    @property
    def rowcount(self) -> int:
        return self._rowcount

    def fetchone(self) -> tuple[Any, ...] | None:
        return self._rows[0] if self._rows else None

    def fetchall(self) -> list[tuple[Any, ...]]:
        return list(self._rows)


class FakeDb:
    """Records SQL + params; models outbox/inbox/dlq tables just enough for the proofs."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, tuple[Any, ...]]] = []
        self._outbox: dict[str, dict[str, Any]] = {}   # event_id -> row
        self._seq = 0
        self._inbox: set[tuple[str, str]] = set()       # (consumer, event_id)
        self._dlq: list[dict[str, Any]] = []

    def execute(self, sql: str, params: Sequence[Any] = ()) -> _Cursor:
        p = tuple(params)
        self.calls.append((sql, p))
        s = " ".join(sql.split())  # normalise whitespace for matching

        if s.startswith("INSERT INTO outbox"):
            event_id, topic, key, payload, occurred = p
            if event_id in self._outbox:
                return _Cursor(0, [])  # ON CONFLICT (event_id) DO NOTHING
            self._seq += 1
            self._outbox[event_id] = {
                "id": self._seq, "event_id": event_id, "topic": topic, "key": key,
                "payload": payload, "occurred_at_ms": occurred, "published_at": None,
            }
            return _Cursor(1, [])

        if s.startswith("SELECT id, event_id, topic"):
            (limit,) = p
            rows = [r for r in self._outbox.values() if r["published_at"] is None]
            rows.sort(key=lambda r: r["id"])
            out = [
                (r["id"], r["event_id"], r["topic"], r["key"], r["payload"], r["occurred_at_ms"])
                for r in rows[:limit]
            ]
            return _Cursor(len(out), out)

        if s.startswith("UPDATE outbox SET published_at"):
            (ids,) = p
            n = 0
            for r in self._outbox.values():
                if r["id"] in ids and r["published_at"] is None:
                    r["published_at"] = "now"
                    n += 1
            return _Cursor(n, [])

        if s.startswith("SELECT 1 FROM inbox"):
            consumer, event_id = p
            hit = (consumer, event_id) in self._inbox
            return _Cursor(1 if hit else 0, [(1,)] if hit else [])

        if s.startswith("INSERT INTO inbox"):
            consumer, event_id = p
            pk = (consumer, event_id)
            if pk in self._inbox:
                return _Cursor(0, [])  # ON CONFLICT (consumer, event_id) DO NOTHING
            self._inbox.add(pk)
            return _Cursor(1, [])

        if s.startswith("INSERT INTO dlq"):
            event_id, topic, key, payload, error, agg = p
            self._dlq.append({
                "event_id": event_id, "topic": topic, "key": key, "payload": payload,
                "error": error, "aggregate_key": agg,
            })
            return _Cursor(1, [])

        if s.startswith("SELECT 1 FROM dlq"):
            (agg,) = p
            hit = any(r["aggregate_key"] == agg for r in self._dlq)
            return _Cursor(1 if hit else 0, [(1,)] if hit else [])

        raise AssertionError(f"unexpected SQL: {s}")


def _rec(event_id: str = "evt-1") -> OutboxRecord:
    return OutboxRecord(
        event_id=event_id, topic="custody.passport.CustodyTransferred.v1",
        key="PPID-1", payload={"ppid": "PPID-1", "qty": 5}, occurred_at_ms=1_700_000_000_000,
    )


# --- Outbox --------------------------------------------------------------------------------------

def test_enqueue_issues_single_insert_with_on_conflict_and_right_columns():
    db = FakeDb()
    inserted = outbox.Outbox.enqueue(db, _rec())

    assert inserted is True
    assert len(db.calls) == 1
    sql, params = db.calls[0]
    norm = " ".join(sql.split())
    assert norm.startswith("INSERT INTO outbox")
    # canonical column set + idempotent conflict clause
    assert 'INSERT INTO outbox(event_id, topic, "key", payload, occurred_at_ms)' in norm
    assert "ON CONFLICT (event_id) DO NOTHING" in norm
    assert params == ("evt-1", "custody.passport.CustodyTransferred.v1", "PPID-1",
                      '{"ppid":"PPID-1","qty":5}', 1_700_000_000_000)


def test_enqueue_duplicate_event_id_is_a_noop():
    db = FakeDb()
    assert outbox.Outbox.enqueue(db, _rec("dup")) is True
    assert outbox.Outbox.enqueue(db, _rec("dup")) is False  # ON CONFLICT DO NOTHING → rowcount 0


def test_relay_fetch_unpublished_then_mark_published():
    db = FakeDb()
    outbox.Outbox.enqueue(db, _rec("a"))
    outbox.Outbox.enqueue(db, _rec("b"))

    rows = outbox.OutboxRelay.fetch_unpublished(db, 10)
    assert [r.event_id for r in rows] == ["a", "b"]  # id order

    marked = outbox.OutboxRelay.mark_published(db, [r.id for r in rows])
    assert marked == 2
    assert outbox.OutboxRelay.fetch_unpublished(db, 10) == []


def test_relay_headers_injects_event_id_and_producer_context_traceparent_optional():
    db = FakeDb()
    outbox.Outbox.enqueue(db, _rec("h"))
    row = outbox.OutboxRelay.fetch_unpublished(db, 1)[0]

    base = outbox.OutboxRelay.headers(row, "custody")
    assert ("event_id", b"h") in base
    assert ("producer_context", b"custody") in base
    assert not any(k == "traceparent" for k, _ in base)  # stub-safe: none passed through

    traced = outbox.OutboxRelay.headers(row, "custody", "00-abc-def-01")
    assert ("traceparent", b"00-abc-def-01") in traced


# --- Inbox ---------------------------------------------------------------------------------------

def test_inbox_mark_then_already_processed_true():
    db = FakeDb()
    assert inbox.Inbox.already_processed(db, "fraud-svc", "evt-9") is False
    assert inbox.Inbox.mark_processed(db, "fraud-svc", "evt-9") is True
    assert inbox.Inbox.already_processed(db, "fraud-svc", "evt-9") is True
    # re-mark is a no-op (ON CONFLICT DO NOTHING)
    assert inbox.Inbox.mark_processed(db, "fraud-svc", "evt-9") is False


def test_inbox_dedup_is_per_consumer():
    db = FakeDb()
    inbox.Inbox.mark_processed(db, "consumer-a", "evt-x")
    assert inbox.Inbox.already_processed(db, "consumer-a", "evt-x") is True
    assert inbox.Inbox.already_processed(db, "consumer-b", "evt-x") is False


# --- DLQ (park-and-freeze) -----------------------------------------------------------------------

def test_dlq_park_records_aggregate_key_and_is_key_parked_only_for_that_key():
    db = FakeDb()
    dlq.Dlq.park(db, DlqEntry(
        event_id="evt-p", topic="finance.wallet.Debited.v1", key="WLT-7",
        payload={"amount": 100}, error="poison: negative balance", aggregate_key="WLT-7",
    ))

    assert dlq.Dlq.is_key_parked(db, "WLT-7") is True
    assert dlq.Dlq.is_key_parked(db, "WLT-8") is False  # other keys keep flowing

    parked = db._dlq[0]
    assert parked["aggregate_key"] == "WLT-7"
    assert parked["error"] == "poison: negative balance"


if __name__ == "__main__":  # pytest-free runner (this environment has no pytest)
    import sys
    tests = sorted((n, f) for n, f in globals().items()
                   if n.startswith("test_") and callable(f))
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print(f"PASS {name}")
        except Exception as exc:  # noqa: BLE001
            failed += 1
            print(f"FAIL {name}: {exc!r}")
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    sys.exit(1 if failed else 0)
