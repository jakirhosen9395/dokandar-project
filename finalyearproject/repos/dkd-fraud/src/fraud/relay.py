"""Outbox relay: at-least-once, ordered, stop-on-first-failure. Headers carry event_id +
producer_context=fraud (fleet R6 convention); downstream inbox dedup absorbs duplicates."""

from __future__ import annotations

import logging
import threading

from confluent_kafka import KafkaException, Producer
from psycopg_pool import ConnectionPool

from fraud import ids, stores

log = logging.getLogger("fraud.relay")


class OutboxRelay:
    def __init__(self, pool: ConnectionPool, brokers: str) -> None:
        self._pool = pool
        self._producer = Producer({
            "bootstrap.servers": brokers,
            "enable.idempotence": True,
            "acks": "all",
            "compression.type": "snappy",
            "allow.auto.create.topics": False,
        })
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, name="outbox-relay", daemon=True)
        self._thread.start()

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                self.drain_once()
            except Exception:
                log.exception("relay drain failed; retrying")
            self._stop.wait(0.5)

    def drain_once(self) -> int:
        published = 0
        with self._pool.connection() as cx:
            rows = stores.fetch_unpublished(cx, 200)
            cx.rollback()
        for row in rows:
            try:
                self._produce_sync(row)
            except KafkaException:
                log.exception("publish failed for %s — stopping this drain (ordering)", row.topic)
                break
            with self._pool.connection() as cx:
                stores.mark_published(cx, row.id, ids.now_ms())
                cx.commit()
            published += 1
        return published

    def _produce_sync(self, row: stores.OutboxRow) -> None:
        done = threading.Event()
        holder: list[object] = []

        def cb(err: object, _msg: object) -> None:
            if err is not None:
                holder.append(err)
            done.set()

        self._producer.produce(
            topic=row.topic,
            key=row.partition_key.encode(),
            value=row.payload.encode(),
            headers=[("event_id", row.event_id.encode()),
                     ("producer_context", b"fraud")],
            on_delivery=cb,
        )
        self._producer.flush(10)
        if not done.is_set() or holder:
            raise KafkaException(holder[0] if holder else "delivery not confirmed")

    def close(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=5)
        self._producer.flush(5)
