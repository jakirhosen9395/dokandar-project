"""Transactional-outbox relay (§10): poll `WHERE sent_at IS NULL FOR UPDATE SKIP LOCKED`,
produce to Kafka (dokandar.risk.*), mark sent — modeled on 13-order/09-payment. Producing
inside the locked tx means a Kafka failure rolls back (retried); SKIP LOCKED is multi-pod
safe. risk_outbox_pending tracks relay lag."""
from __future__ import annotations
import asyncio
import json
import logging

from aiokafka import AIOKafkaProducer

from app.config import settings
from app.db.postgres import pool
from app.observability.metrics import SERVICE_VAL, risk_outbox_pending

log = logging.getLogger("risk.outbox")
_producer: AIOKafkaProducer | None = None
_task: asyncio.Task | None = None


async def _refresh_gauge() -> None:
    try:
        async with pool().acquire() as conn:
            n = await conn.fetchval("SELECT count(*) FROM outbox WHERE sent_at IS NULL")
        risk_outbox_pending.labels(SERVICE_VAL).set(n or 0)
    except Exception:
        pass


async def _relay_once() -> int:
    count = 0
    async with pool().acquire() as conn:
        async with conn.transaction():
            rows = await conn.fetch("""
                SELECT id, topic, key, payload FROM outbox
                WHERE sent_at IS NULL ORDER BY created_at LIMIT 100
                FOR UPDATE SKIP LOCKED
            """)
            for r in rows:
                payload = r["payload"]
                body = payload.encode() if isinstance(payload, str) else json.dumps(payload).encode()
                await _producer.send_and_wait(r["topic"], body, key=(r["key"] or "").encode())
                await conn.execute("UPDATE outbox SET sent_at = now() WHERE id = $1", r["id"])
                count += 1
    return count


async def _loop() -> None:
    while True:
        try:
            n = await _relay_once()
            await _refresh_gauge()
            await asyncio.sleep(0.05 if n else 1.0)
        except asyncio.CancelledError:
            break
        except Exception:
            log.exception("outbox relay error")
            await asyncio.sleep(2)


async def start() -> None:
    global _producer, _task
    if not settings.kafka_bootstrap:
        return
    _producer = AIOKafkaProducer(bootstrap_servers=settings.kafka_bootstrap, acks="all")
    await _producer.start()
    _task = asyncio.create_task(_loop())
    log.info("risk outbox relay started")


async def stop() -> None:
    global _producer, _task
    if _task:
        _task.cancel()
        try:
            await _task
        except asyncio.CancelledError:
            pass
    if _producer:
        try:
            await _producer.stop()
        except Exception:
            pass
    _producer = None
    _task = None
