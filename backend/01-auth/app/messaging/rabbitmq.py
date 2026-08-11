"""RabbitMQ task producer (e.g. notifications.otp.send)."""
from __future__ import annotations
import json
import logging
from typing import Optional
import aio_pika
from app.config import settings

log = logging.getLogger("auth.rabbitmq")
_connection: Optional[aio_pika.RobustConnection] = None
_channel: Optional[aio_pika.RobustChannel] = None


async def connect():
    global _connection, _channel
    if _connection is None or _connection.is_closed:
        _connection = await aio_pika.connect_robust(settings.rabbitmq_url)
        _channel = await _connection.channel()
        # declare the OTP queue (durable + DLQ ready)
        await _channel.declare_queue(
            settings.rabbitmq_otp_queue,
            durable=True,
            arguments={"x-dead-letter-exchange": "", "x-dead-letter-routing-key": f"{settings.rabbitmq_otp_queue}.dlq"},
        )
        await _channel.declare_queue(f"{settings.rabbitmq_otp_queue}.dlq", durable=True)
        log.info("rabbitmq connected; queue=%s", settings.rabbitmq_otp_queue)


async def enqueue_otp(phone: str, code: str, purpose: str) -> None:
    await connect()
    msg = aio_pika.Message(
        body=json.dumps({"phone": phone, "code": code, "purpose": purpose, "ttl": settings.otp_ttl_seconds}).encode(),
        delivery_mode=aio_pika.DeliveryMode.PERSISTENT,
        content_type="application/json",
    )
    await _channel.default_exchange.publish(msg, routing_key=settings.rabbitmq_otp_queue)


async def close():
    global _connection
    if _connection and not _connection.is_closed:
        await _connection.close()
    _connection = None


async def health_check() -> bool:
    try:
        await connect()
        return _channel is not None and not _channel.is_closed
    except Exception as e:
        log.warning("rabbitmq health check failed: %s", e)
        return False
