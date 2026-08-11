"""Ingest worker: 45 registry topics → routed ClickHouse facts. Replay-safe by construction
(ReplacingMergeTree keyed on event_id); offsets commit only after the insert succeeds, so a
crash replays the record and the dedup key absorbs it (FR-ANL-002/009)."""

from __future__ import annotations

import hashlib
import json
import logging
import threading
from typing import Any

from clickhouse_connect.driver.client import Client
from confluent_kafka import Consumer

from analytics import advisory, ch, routing

log = logging.getLogger("analytics.consumer")


FLUSH_ROWS = 500
FLUSH_SECONDS = 1.0


class IngestWorker:
    def __init__(self, client: Client, brokers: str) -> None:
        self._ch = client
        self._consumer = Consumer({
            "bootstrap.servers": brokers,
            "group.id": "analytics-svc",
            "enable.auto.commit": False,
            "auto.offset.reset": "earliest",
            "allow.auto.create.topics": False,
        })
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        self._consumer.subscribe(list(routing.CONSUMED_TOPICS))
        self._thread = threading.Thread(target=self._run, name="ingest-worker", daemon=True)
        self._thread.start()

    def _run(self) -> None:
        log.info("ingesting %d registry topics", len(routing.CONSUMED_TOPICS))
        # Batched inserts (reviewer H-2): one part per message drowns MergeTree in tiny
        # parts. Offsets commit only AFTER the batch flush — a crash replays the batch and
        # the event_id-keyed ReplacingMergeTree absorbs it.
        buffer: dict[str, list[dict[str, Any]]] = {}
        buffered = 0
        last_flush = advisory.now_ms()
        while not self._stop.is_set():
            msg = self._consumer.poll(0.2)
            if msg is not None and msg.error():
                log.error("consumer error: %s", msg.error())
                msg = None
            if msg is not None:
                payload = parse(msg.value())
                event_id = extract_event_id(dict_headers(msg.headers()), payload,
                                            msg.topic() or "")
                for table, row in routing.route(msg.topic() or "", event_id, payload,
                                                advisory.now_ms()):
                    buffer.setdefault(table, []).append(row)
                    buffered += 1
            age = advisory.now_ms() - last_flush
            if buffered and (buffered >= FLUSH_ROWS or age >= FLUSH_SECONDS * 1000):
                try:
                    for table, rows in buffer.items():
                        ch.insert_rows(self._ch, table, rows)
                    self._consumer.commit(asynchronous=False)
                    buffer.clear()
                    buffered = 0
                except Exception:
                    # F-3: do NOT clear the buffer or commit on failure — that silently dropped the
                    # batch (the next successful commit then advanced PAST it). Keep the rows and retry
                    # the same batch next iteration; re-inserts are idempotent under ReplacingMergeTree.
                    log.exception("batch flush failed — retrying the SAME batch (no drop, no offset advance)")
                    self._stop.wait(2)
                last_flush = advisory.now_ms()

    def close(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=8)
        self._consumer.close()


def dict_headers(raw: Any) -> dict[str, bytes]:
    out: dict[str, bytes] = {}
    for item in raw or []:
        if isinstance(item, tuple) and len(item) == 2 and isinstance(item[1], bytes):
            out[str(item[0])] = item[1]
    return out


def parse(raw: bytes | None) -> dict[str, Any]:
    if not raw:
        return {}
    try:
        loaded = json.loads(raw.decode())
    except (json.JSONDecodeError, UnicodeDecodeError):
        return {}
    return loaded if isinstance(loaded, dict) else {}


def extract_event_id(headers: dict[str, bytes], payload: dict[str, Any], topic: str) -> str:
    h = headers.get("event_id")
    if h:
        return h.decode()
    for k in ("eventId", "event_id"):
        v = payload.get(k)
        if isinstance(v, str) and v:
            return v
    # F-4: every real spine event carries an eventId; if one is genuinely absent, derive a
    # CONTENT-unique key (never the old collapsing "{topic}/{occurredAt}", which merged distinct
    # same-topic/same-timestamp events under ReplacingMergeTree).
    digest = hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":"), default=str).encode()
    ).hexdigest()
    return f"{topic}/{digest}"
