"""18-risk-trust consumer — shipment.failed_delivery for COD refusal labels."""
from __future__ import annotations
import asyncio, json, logging
import elasticapm
from aiokafka import AIOKafkaConsumer
from aiokafka.errors import KafkaError

from app.config import settings
from app.risk import service as svc

log = logging.getLogger("risk.projectors")
_tasks: list[asyncio.Task] = []


async def _on_cod_refusal(ev: dict) -> None:
    user_id = ev.get("user_id") or ev.get("customer_id")
    order_id = ev.get("order_id")
    if not (user_id and order_id): return
    if (ev.get("payment_method") or "").lower() != "cod": return
    await svc.record_cod_refusal(str(user_id), str(order_id))


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
            # visible (Kafka as a messaging source) and the handler's DB writes correlate.
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
                log.exception("risk projector %s failed", name)
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
    _tasks.append(asyncio.create_task(_run("cod_refusal", settings.kafka_topic_shipment_failed, _on_cod_refusal)))


async def stop_all() -> None:
    for t in _tasks: t.cancel()
    for t in _tasks:
        try: await t
        except asyncio.CancelledError: pass
    _tasks.clear()
