"""Wire + run: ClickHouse DDL, ingest worker thread, FastAPI via uvicorn."""

from __future__ import annotations

import logging
import signal
import sys
from types import FrameType
from typing import Any

import uvicorn

from analytics import api, ch
from analytics.config import load
from analytics.consumer import IngestWorker

logging.basicConfig(
    level=logging.INFO,
    format='{"ts":"%(asctime)s","lvl":"%(levelname)s","log":"%(name)s","msg":"%(message)s"}')
log = logging.getLogger("analytics.main")


def main() -> None:
    cfg = load()
    client = ch.open_client(cfg.ch_url, cfg.ch_user, cfg.ch_password)
    ch.migrate(client)

    query_clients = ch.ThreadLocalClients(cfg.ch_url, cfg.ch_user, cfg.ch_password)

    def run_query(sql: str, params: dict[str, Any]) -> list[dict[str, Any]]:
        return ch.query(query_clients.get(), sql, params)

    def health_probe() -> bool:
        try:
            query_clients.get().command("SELECT 1")
            return True
        except Exception:
            return False

    worker = IngestWorker(client, cfg.kafka_brokers)
    app = api.build_app(cfg, run_query, health_probe)
    worker.start()

    def shutdown(_sig: int, _frm: FrameType | None) -> None:
        log.info("shutting down")
        worker.close()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    uvicorn.run(app, host="0.0.0.0", port=cfg.port, log_level="info")


if __name__ == "__main__":
    main()
