"""Wire + run: migrations, relay/consumer/rabbit threads, FastAPI via uvicorn."""

from __future__ import annotations

import logging
import signal
import sys
from types import FrameType
from typing import Any

import uvicorn

from fraud import api, db, ids
from fraud.config import load, validate
from fraud.consumer import SpineConsumer
from fraud.rabbit import Rabbit
from fraud.redisstore import RiskStore
from fraud.relay import OutboxRelay
from fraud.service import FraudService

logging.basicConfig(level=logging.INFO,
                    format='{"ts":"%(asctime)s","lvl":"%(levelname)s","log":"%(name)s","msg":"%(message)s"}')
log = logging.getLogger("fraud.main")


def main() -> None:
    cfg = load()
    validate(cfg)
    pool = db.open_pool(cfg.db_dsn)
    db.migrate(pool, ids.now_ms())

    risk = RiskStore(cfg.redis_url, cfg.velocity_window_ms, cfg.profile_ttl_s)
    rabbit = Rabbit(cfg.rabbit_url)
    fraud = FraudService(pool, rabbit)
    relay = OutboxRelay(pool, cfg.kafka_brokers)
    consumer = SpineConsumer(pool, risk, cfg.kafka_brokers,
                             cfg.velocity_threshold, cfg.model_version)

    def health_probe() -> dict[str, bool]:
        db_ok = True
        try:
            with pool.connection() as cx:
                cx.execute("SELECT 1")
                cx.rollback()
        except Exception:
            db_ok = False
        return {"db": db_ok, "redis": risk.ping()}

    app = api.build_app(cfg, fraud, consumer.profile, health_probe)

    relay.start()
    consumer.start()
    rabbit.start_consumer()

    def shutdown(_sig: int, _frm: FrameType | None) -> None:
        log.info("shutting down")
        consumer.close()
        relay.close()
        rabbit.close()
        pool.close()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    config: dict[str, Any] = {"host": "0.0.0.0", "port": cfg.port, "log_level": "info"}
    uvicorn.run(app, **config)


if __name__ == "__main__":
    main()
