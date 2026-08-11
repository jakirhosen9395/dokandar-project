"""16-recommendation Kafka consumers — project events into interaction_log."""
from __future__ import annotations
import asyncio, json, logging
import elasticapm
from aiokafka import AIOKafkaConsumer
from aiokafka.errors import KafkaError

from app.config import settings
from app.reco import service as svc

log = logging.getLogger("reco.projectors")
_tasks: list[asyncio.Task] = []


async def _on_product(ev: dict) -> None:
    # product.changed — refresh popularity baseline implicitly via interactions
    pass


async def _on_order(ev: dict) -> None:
    user_id = ev.get("customer_id") or ev.get("user_id")
    for so in (ev.get("sub_orders") or []):
        for ln in (so.get("items") or []):
            await svc.ingest_interaction(
                user_id, "order", product_id=ln.get("product_id"),
                shop_id=so.get("shop_id"),
                source_event_id=f"{ev.get('order_id')}:{ln.get('product_id')}")
    if not ev.get("sub_orders") and ev.get("product_id"):
        await svc.ingest_interaction(user_id, "order",
            product_id=ev.get("product_id"), shop_id=ev.get("shop_id"),
            source_event_id=ev.get("order_id"))


async def _on_review(ev: dict) -> None:
    await svc.ingest_interaction(
        ev.get("user_id"), "review", product_id=ev.get("product_id"),
        shop_id=ev.get("shop_id"), source_event_id=ev.get("review_id"))


async def _run(name: str, topic: str, handler) -> None:
    consumer = AIOKafkaConsumer(topic,
        bootstrap_servers=settings.kafka_bootstrap,
        group_id=f"{settings.kafka_group_prefix}-{name}",
        enable_auto_commit=False, auto_offset_reset="earliest")
    while True:
        try: await consumer.start(); break
        except KafkaError: await asyncio.sleep(5)
    try:
        async for msg in consumer:
            if msg.value is None:
                await consumer.commit(); continue
            # aiokafka is not auto-instrumented — open a transaction per message so the consume is
            # visible (Kafka as a messaging source) and the projector's DB writes/logs correlate.
            client = elasticapm.get_client()
            if client is not None:
                client.begin_transaction("messaging")
            result = "success"
            try:
                ev = json.loads(msg.value)
                await handler(ev)
                await consumer.commit()
            except Exception:
                result = "failure"
                log.exception("reco projector %s failed", name)
                if client is not None:
                    client.capture_exception()
                await asyncio.sleep(2)
            finally:
                if client is not None:
                    client.end_transaction(f"Kafka RECEIVE from {topic}", result)
    except asyncio.CancelledError: pass
    finally:
        try: await consumer.stop()
        except Exception: pass


async def start_all() -> None:
    spec = [("product", settings.kafka_topic_product, _on_product),
            ("order",   settings.kafka_topic_order,   _on_order),
            ("review",  settings.kafka_topic_review,  _on_review)]
    for n, t, h in spec:
        _tasks.append(asyncio.create_task(_run(n, t, h)))


async def stop_all() -> None:
    for t in _tasks: t.cancel()
    for t in _tasks:
        try: await t
        except asyncio.CancelledError: pass
    _tasks.clear()
