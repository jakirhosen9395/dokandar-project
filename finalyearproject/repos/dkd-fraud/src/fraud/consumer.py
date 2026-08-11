"""Spine consumer (consumer=10 registry rows): identity KYC/suspension events + OrderPlaced +
TradeOrderCreated feed the velocity feature store. Inbox dedup runs in the same transaction
as any Postgres effect; Redis bumps are idempotent per event_id (sorted-set member), so the
at-least-once replay of a Kafka record never double-counts a feature."""

from __future__ import annotations

import json
import logging
import threading
from typing import Any

from confluent_kafka import Consumer
from psycopg_pool import ConnectionPool

from fraud import events, ids, rules, stores
from fraud.redisstore import RiskStore

log = logging.getLogger("fraud.consumer")

# FRAUD-06: a poison record is retried INLINE up to MAX_HANDLE_ATTEMPTS, then parked to the DLQ.
MAX_HANDLE_ATTEMPTS = 8
HANDLE_RETRY_BACKOFF_S = 1.5


class SpineConsumer:
    def __init__(self, pool: ConnectionPool, risk: RiskStore, brokers: str,
                 velocity_threshold: int, model_version: str) -> None:
        self._pool = pool
        self._risk = risk
        self._threshold = velocity_threshold
        self._model_version = model_version
        self._consumer = Consumer({
            "bootstrap.servers": brokers,
            "group.id": "fraud-svc",
            "enable.auto.commit": False,
            "auto.offset.reset": "earliest",
            "allow.auto.create.topics": False,
        })
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        self._consumer.subscribe(list(events.CONSUMED_TOPICS))
        self._thread = threading.Thread(target=self._run, name="spine-consumer", daemon=True)
        self._thread.start()

    def _run(self) -> None:
        while not self._stop.is_set():
            msg = self._consumer.poll(1.0)
            if msg is None:
                continue
            if msg.error():
                log.error("consumer error: %s", msg.error())
                continue
            headers: dict[str, bytes] = {}
            for item in msg.headers() or []:
                if isinstance(item, tuple) and len(item) == 2 and isinstance(item[1], bytes):
                    headers[str(item[0])] = item[1]
            # FRAUD-06: bounded INLINE retry (confluent-kafka does not re-deliver an uncommitted record
            # within a session — committing the NEXT record would silently skip this one), then park to
            # the DLQ and commit so the partition advances instead of blocking/skipping.
            for attempt in range(1, MAX_HANDLE_ATTEMPTS + 1):
                try:
                    self._handle(msg.topic() or "", msg.value(), headers)
                    self._consumer.commit(message=msg, asynchronous=False)
                    break
                except Exception as exc:
                    if attempt < MAX_HANDLE_ATTEMPTS:
                        log.warning("handler failed on %s (attempt %d) — inline retry", msg.topic(), attempt)
                        self._stop.wait(HANDLE_RETRY_BACKOFF_S)
                        continue
                    # retries exhausted → quarantine and advance (park-insert failure keeps it uncommitted)
                    try:
                        self._park_dlq(msg, headers, f"{type(exc).__name__}: {exc}")
                        self._consumer.commit(message=msg, asynchronous=False)
                        log.error("fraud poison event PARKED to DLQ after %d retries: %s",
                                  MAX_HANDLE_ATTEMPTS, msg.topic())
                    except Exception:
                        log.exception("DLQ park FAILED — leaving uncommitted (never drop): %s", msg.topic())
                        self._stop.wait(2)

    def _handle(self, topic: str, raw: bytes | None, headers: dict[str, bytes]) -> None:
        payload = _parse(raw)
        event_id = _event_id(headers, payload, topic)
        with self._pool.connection() as cx:
            seen = stores.inbox_seen(cx, event_id)
            cx.rollback()
        if seen:
            return  # duplicate delivery
        # Effects FIRST, inbox mark LAST: the Redis bump is idempotent per event_id, so a
        # crash between them replays harmlessly — the reverse order can mark an event as
        # processed while its feature write failed (lesson from the first deploy).
        did = _subject_did(topic, payload)
        if did is not None:
            occurred = payload.get("occurredAt")
            at_ms = occurred if isinstance(occurred, int) else ids.now_ms()
            if topic == "b2c.order.OrderPlaced.v1":
                self._risk.bump("orders", did, event_id, at_ms)
            elif topic == "b2b.tradeorder.TradeOrderCreated.v1":
                self._risk.bump("trades", did, event_id, at_ms)
            # every feature-relevant event refreshes the advisory RiskProfile
            self._refresh_profile(did)
        else:
            log.info("skip %s — no subject DID in payload", topic)
        with self._pool.connection() as cx:
            stores.inbox_try_mark(cx, event_id, topic, ids.now_ms())
            cx.commit()

    def _refresh_profile(self, did: str) -> dict[str, Any]:
        now = ids.now_ms()
        orders = self._risk.count("orders", did, now)
        trades = self._risk.count("trades", did, now)
        a = rules.assess(orders, trades, self._threshold)
        return self._risk.profile_for(did, orders, trades, {
            "riskScore": a.risk_score, "band": a.band, "ruleFlags": a.rule_flags,
            "recommendation": a.recommendation, "modelVersion": self._model_version,
            "advisory": True,
        })

    def profile(self, did: str) -> dict[str, Any]:
        cached = self._risk.get_profile(did)
        return cached if cached is not None else self._refresh_profile(did)

    def _park_dlq(self, msg: Any, headers: dict[str, bytes], error: str) -> None:
        """FRAUD-06: quarantine a poison record to the DLQ (idempotent-ish; append-only sink)."""
        payload = _parse(msg.value())
        event_id = _event_id(headers, payload, msg.topic() or "")
        key = msg.key().decode() if msg.key() else ""
        raw = msg.value().decode() if msg.value() else "{}"
        with self._pool.connection() as cx:
            cx.execute(
                "INSERT INTO dlq(event_id, topic, key, payload, error, parked_at) "
                "VALUES (%s,%s,%s,%s,%s,%s)",
                (event_id, msg.topic() or "", key, raw, error[:1000], ids.now_ms()),
            )
            cx.commit()

    def close(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=8)
        self._consumer.close()


def _parse(raw: bytes | None) -> dict[str, Any]:
    if not raw:
        return {}
    try:
        loaded = json.loads(raw.decode())
    except (json.JSONDecodeError, UnicodeDecodeError):
        return {}
    return loaded if isinstance(loaded, dict) else {}


def _event_id(headers: dict[str, bytes], payload: dict[str, Any], topic: str) -> str:
    h = headers.get("event_id")
    if h:
        return h.decode()
    for k in ("eventId", "event_id"):
        v = payload.get(k)
        if isinstance(v, str) and v:
            return v
    return f"{topic}/{payload.get('occurredAt', 'unknown')}"


_TOPIC_DID_FIELDS: dict[str, tuple[str, ...]] = {
    # velocity/COD-abuse features target the PURCHASING actor (FR-SCM-019)
    "b2c.order.OrderPlaced.v1": ("buyerDid",),
    "b2b.tradeorder.TradeOrderCreated.v1": ("buyerDid",),
    "identity.party.KYCApproved.v1": ("did", "Did"),
    "identity.party.KYCTierChanged.v1": ("did", "Did"),
    "identity.party.PartySuspended.v1": ("did", "Did"),
}


def _subject_did(topic: str, p: dict[str, Any]) -> str | None:
    """Explicit per-topic attribution (reviewer MEDIUM) — a schema drift surfaces as a
    logged skip on a NAMED field, never a silent mis-attribution."""
    for k in _TOPIC_DID_FIELDS.get(topic, ()):
        v = p.get(k)
        if isinstance(v, str) and ids.is_did(v):
            return v
    return None
