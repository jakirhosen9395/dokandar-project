"""11-reporting Kafka consumer — projects fleet events into PG facts.
Consume-only · commit AFTER fact + consumer_offsets commit (at-least-once)."""
from __future__ import annotations
import asyncio, json, logging
import elasticapm
from aiokafka import AIOKafkaConsumer
from aiokafka.errors import KafkaError

from app.config import settings
from app.db.postgres import pool
from app.observability.metrics import (
    SERVICE_VAL, reporting_facts_upserted_total, reporting_projection_lag,
)

log = logging.getLogger("reporting.projectors")
_tasks: list[asyncio.Task] = []


async def _upsert_fact_order(ev: dict) -> None:
    sub_order_id = ev.get("sub_order_id") or ev.get("order_id") or ev.get("id")
    order_id = ev.get("order_id") or sub_order_id
    customer_id = ev.get("customer_id") or ev.get("user_id")
    shop_id = ev.get("shop_id")
    state = ev.get("state") or ev.get("status") or "placed"
    total = int(ev.get("total_minor") or ev.get("subtotal_minor") or ev.get("amount_minor") or 0)
    if not (sub_order_id and customer_id and shop_id):
        return
    async with pool().acquire() as conn:
        await conn.execute("""
            INSERT INTO fact_order (sub_order_id, order_id, customer_id, shop_id,
                                     shopkeeper_id, state, total_minor, placed_at, date_key)
            VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6, $7, now(), now()::date)
            ON CONFLICT (sub_order_id) DO UPDATE
              SET state = EXCLUDED.state, total_minor = EXCLUDED.total_minor, updated_at = now()
        """, sub_order_id, order_id, customer_id, shop_id, ev.get("shopkeeper_id"), state, total)


async def _upsert_order_status(ev: dict) -> None:
    sub_order_id = ev.get("sub_order_id") or ev.get("order_id")
    to_state = ev.get("to_state") or ev.get("state")
    changed_at = ev.get("changed_at")
    if not (sub_order_id and to_state): return
    async with pool().acquire() as conn:
        async with conn.transaction():
            await conn.execute("""
                INSERT INTO fact_order_state_change (sub_order_id, to_state, changed_at)
                VALUES ($1::uuid, $2, coalesce($3::timestamptz, now()))
                ON CONFLICT DO NOTHING
            """, sub_order_id, to_state, changed_at)
            await conn.execute("""
                UPDATE fact_order SET state = $2, updated_at = now()
                  ${delivered}
                WHERE sub_order_id = $1::uuid
            """.replace("${delivered}", ", delivered_at = now()" if to_state == "delivered" else ""),
                sub_order_id, to_state)


async def _upsert_fact_payment(ev: dict) -> None:
    intent_id = ev.get("intent_id") or ev.get("id")
    if not intent_id: return
    async with pool().acquire() as conn:
        await conn.execute("""
            INSERT INTO fact_payment (intent_id, order_id, amount_minor, commission_minor,
                                       net_to_shopkeeper_minor, provider, settled_at, date_key)
            VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6, now(), now()::date)
            ON CONFLICT (intent_id) DO NOTHING
        """, intent_id, ev.get("order_id"),
             int(ev.get("amount_minor") or 0),
             int(ev.get("commission_minor") or 0),
             int(ev.get("net_to_shopkeeper_minor") or 0),
             ev.get("provider") or "unknown")


async def _upsert_fact_payout(ev: dict) -> None:
    payout_id = ev.get("payout_id") or ev.get("id")
    if not payout_id: return
    async with pool().acquire() as conn:
        await conn.execute("""
            INSERT INTO fact_payout (payout_id, shopkeeper_id, amount_minor, state, completed_at, date_key)
            VALUES ($1::uuid, $2::uuid, $3, $4, now(), now()::date)
            ON CONFLICT (payout_id) DO UPDATE SET state = EXCLUDED.state, completed_at = now()
        """, payout_id, ev.get("shopkeeper_id"),
             int(ev.get("amount_minor") or 0),
             ev.get("state") or "succeeded")


async def _run(name: str, topic: str, handler) -> None:
    group = f"{settings.kafka_group_prefix}-{name}"
    consumer = AIOKafkaConsumer(topic,
        bootstrap_servers=settings.kafka_bootstrap, group_id=group,
        enable_auto_commit=False, auto_offset_reset="earliest")
    while True:
        try:
            await consumer.start(); break
        except KafkaError:
            await asyncio.sleep(5)
    try:
        async for msg in consumer:
            if msg.value is None:
                await consumer.commit(); continue
            # aiokafka is not auto-instrumented — open a transaction per message so the consume is
            # visible (Kafka as a messaging source) and the projector's PG upserts/logs correlate.
            client = elasticapm.get_client()
            if client is not None:
                client.begin_transaction("messaging")
            result = "success"
            try:
                ev = json.loads(msg.value)
                # Defensive contract check: a projector handler expects a JSON OBJECT (dict). A
                # malformed/non-object payload (e.g. a bare JSON string → "'str' object has no
                # attribute 'get'") is rejected gracefully — logged with the offset and COMMITTED
                # (so it is not retried forever) instead of raising an uncaught AttributeError.
                if not isinstance(ev, dict):
                    log.warning("projector %s offset=%d skipped: payload is %s, expected JSON object",
                                name, msg.offset, type(ev).__name__)
                    await consumer.commit()
                else:
                    await handler(ev)
                    await consumer.commit()
                    reporting_facts_upserted_total.labels(SERVICE_VAL, topic).inc()
            except Exception:
                result = "failure"
                log.exception("projector %s offset=%d failed", name, msg.offset)
                if client is not None:
                    client.capture_exception()
                await asyncio.sleep(2)
            finally:
                if client is not None:
                    client.end_transaction(f"Kafka RECEIVE from {topic}", result)
    except asyncio.CancelledError:
        pass
    finally:
        try: await consumer.stop()
        except Exception: pass


async def start_all() -> None:
    spec = [
        ("order_placed", settings.kafka_topic_order_placed, _upsert_fact_order),
        ("order_status", settings.kafka_topic_order_status, _upsert_order_status),
        ("payment_settled", settings.kafka_topic_payment_settled, _upsert_fact_payment),
        ("payout_completed", settings.kafka_topic_payout_completed, _upsert_fact_payout),
    ]
    for name, topic, h in spec:
        _tasks.append(asyncio.create_task(_run(name, topic, h)))
    log.info("4 reporting projectors started")


async def stop_all() -> None:
    for t in _tasks: t.cancel()
    for t in _tasks:
        try: await t
        except asyncio.CancelledError: pass
    _tasks.clear()
