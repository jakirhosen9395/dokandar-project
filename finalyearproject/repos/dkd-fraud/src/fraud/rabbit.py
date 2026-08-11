"""Intra-context RabbitMQ (R6: NEVER cross-context). The four-eyes second-approver queue
`fraud.hold-approval-request` carries AccountHoldRequested messages (DM M2). A small consumer
thread mirrors requests into a log table-free structure — the pending_holds row is already the
materialized work item, so the consumer only acknowledges + logs for the approver console."""

from __future__ import annotations

import json
import logging
import threading
from collections import deque
from typing import Any

import pika

log = logging.getLogger("fraud.rabbit")

QUEUE_HOLD_APPROVAL = "fraud.hold-approval-request"


class Rabbit:
    def __init__(self, url: str) -> None:
        self._params = pika.URLParameters(url)
        self._lock = threading.Lock()
        self._conn: pika.BlockingConnection | None = None
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._seen: deque[dict[str, Any]] = deque(maxlen=100)

    def publish_hold_request(self, message: dict[str, Any]) -> None:
        # BlockingConnection is NOT thread-safe: the whole publish sequence holds the lock
        # (reviewer HIGH). The consumer loop uses its own dedicated connection.
        with self._lock:
            try:
                if self._conn is None or self._conn.is_closed:
                    self._conn = pika.BlockingConnection(self._params)
                ch = self._conn.channel()
                ch.queue_declare(queue=QUEUE_HOLD_APPROVAL, durable=True)
                ch.basic_publish(
                    exchange="",
                    routing_key=QUEUE_HOLD_APPROVAL,
                    body=json.dumps(message).encode(),
                    properties=pika.BasicProperties(delivery_mode=2,
                                                    content_type="application/json"),
                )
                ch.close()
            except Exception:
                # The pending_holds row is the durable work item; the queue message is the
                # notification channel. A publish failure is logged, never silently swallowed.
                log.exception("hold-approval-request publish failed (pending hold row persists)")

    def start_consumer(self) -> None:
        self._thread = threading.Thread(target=self._consume, name="rabbit-consumer", daemon=True)
        self._thread.start()

    def _consume(self) -> None:
        while not self._stop.is_set():
            try:
                conn = pika.BlockingConnection(self._params)
                ch = conn.channel()
                ch.queue_declare(queue=QUEUE_HOLD_APPROVAL, durable=True)
                for method, _props, body in ch.consume(QUEUE_HOLD_APPROVAL, inactivity_timeout=2):
                    if self._stop.is_set():
                        break
                    if method is None:
                        continue
                    try:
                        msg = json.loads(body.decode())
                        log.info("hold approval requested for %s by %s",
                                 msg.get("subjectDid"), msg.get("approver1"))
                        self._seen.append(msg)
                    finally:
                        ch.basic_ack(method.delivery_tag)
                ch.cancel()
                conn.close()
            except Exception:
                if not self._stop.is_set():
                    log.exception("rabbit consumer reconnecting")
                    self._stop.wait(3)

    def recent_requests(self) -> list[dict[str, Any]]:
        return list(self._seen)

    def close(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=5)
        with self._lock:
            if self._conn is not None and self._conn.is_open:
                self._conn.close()
