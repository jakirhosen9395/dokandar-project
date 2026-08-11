"""Outbox-relayed Kafka producer."""
from __future__ import annotations
import asyncio
import json
import logging
from datetime import datetime, timezone
from typing import Optional
from confluent_kafka import Producer
from sqlalchemy import select, update
from app.config import settings
from app.db.models import Outbox
from app.db.session import SessionLocal
from app.observability import metrics as M

log = logging.getLogger("auth.kafka")
_producer: Optional[Producer] = None


def get_producer() -> Producer:
    global _producer
    if _producer is None:
        _producer = Producer({
            "bootstrap.servers": settings.kafka_bootstrap,
            "acks": "all",
            "enable.idempotence": True,
            "retries": 5,
            "client.id": f"{settings.service_name}-{settings.app_env}",
        })
    return _producer


async def outbox_relay_loop(interval_seconds: float = 2.0):
    """Background task: poll outbox table, publish unsent rows, mark sent."""
    log.info("outbox-relay started (interval=%ss)", interval_seconds)
    while True:
        try:
            await _relay_once()
        except Exception:
            log.exception("outbox-relay tick failed")
        await asyncio.sleep(interval_seconds)


async def _relay_once() -> int:
    p = get_producer()
    delivered: list[str] = []

    async with SessionLocal() as db:
        rows = (await db.execute(
            select(Outbox).where(Outbox.sent_at.is_(None)).limit(100)
        )).scalars().all()

        if not rows:
            return 0

        def _ack(err, msg, *, row_id=None):
            if err is not None:
                log.error("kafka deliver failed for %s: %s", row_id, err)
                return
            delivered.append(row_id)

        for row in rows:
            try:
                p.produce(
                    topic=row.topic,
                    key=(row.key or "").encode() if row.key else None,
                    value=json.dumps(row.payload).encode(),
                    on_delivery=lambda err, msg, rid=str(row.id): _ack(err, msg, row_id=rid),
                )
            except BufferError:
                p.poll(1.0)
                continue
        p.flush(10)

        if delivered:
            await db.execute(
                update(Outbox)
                .where(Outbox.id.in_(delivered))
                .values(sent_at=datetime.now(timezone.utc))
            )
            await db.commit()
            log.info("outbox: marked %d sent", len(delivered))
            M.outbox_relayed.inc(len(delivered))
        return len(delivered)


def health_check() -> bool:
    try:
        p = get_producer()
        # list_topics with a short timeout; raises on broker unreachable
        p.list_topics(timeout=3)
        return True
    except Exception as e:
        log.warning("kafka health check failed: %s", e)
        return False
