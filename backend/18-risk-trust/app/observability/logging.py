"""Three log sinks: stdout (pretty JSON) + Mongo + ES (ECS) — same pattern
as the rest of the fleet. _id-strip before ES bulk."""
from __future__ import annotations

import asyncio
import json
import logging
import sys
from datetime import datetime, timezone
from typing import Any

import elasticapm
import httpx
from pymongo import MongoClient

from app.config import settings


def _iso_millis(epoch: float) -> str:
    """ECS @timestamp as a VALID ISO-8601 millis string. logging.Formatter.formatTime
    uses time.strftime which does NOT support %f → a literal '%f' makes ES reject every
    doc as an invalid date (while Mongo silently accepts the string). Format via datetime."""
    dt = datetime.fromtimestamp(epoch, tz=timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond // 1000:03d}Z"


def _trace_fields() -> dict:
    """Trace correlation via the module-level helpers (work for agent-started
    transactions too, unlike tx.trace_parent.trace_id which is None for those)."""
    out: dict[str, Any] = {}
    try:
        tid = elasticapm.get_trace_id()
        xid = elasticapm.get_transaction_id()
        if tid:
            out["trace"] = {"id": tid}
        if xid:
            out["transaction"] = {"id": xid}
    except Exception:  # noqa: BLE001
        pass
    return out


_MAX_QUEUE = 10_000
_BATCH = 200
_DRAIN_INTERVAL_S = 0.5

_mongo_q: asyncio.Queue[dict] | None = None
_es_q: asyncio.Queue[dict] | None = None
_mongo_client: MongoClient | None = None
_es_client: httpx.AsyncClient | None = None
_mongo_task: asyncio.Task | None = None
_es_task: asyncio.Task | None = None


class PrettyJsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        dt = datetime.fromtimestamp(record.created, tz=timezone.utc)
        out: dict[str, Any] = {
            "asctime": dt.strftime("%Y-%m-%d %H:%M:%S,") + f"{dt.microsecond // 1000:03d}",
            "name": record.name,
            "levelname": record.levelname,
            "message": record.getMessage(),
            "elasticapm_service_name": settings.apm_service_name,
        }
        tf = _trace_fields()
        if "trace" in tf:
            out["elasticapm_trace_id"] = tf["trace"]["id"]
        if "transaction" in tf:
            out["elasticapm_transaction_id"] = tf["transaction"]["id"]
        if record.exc_info:
            out["exception"] = self.formatException(record.exc_info)
        return json.dumps(out, indent=2, ensure_ascii=False)


def _record_to_doc(record: logging.LogRecord) -> dict:
    doc: dict[str, Any] = {
        "@timestamp": _iso_millis(record.created),
        "log": {"level": record.levelname.lower()},
        "logger": record.name,
        "message": record.getMessage(),
        "service": {"name": settings.service_name, "environment": settings.app_env},
        "labels": {"tenant": settings.tenant, "env_version": settings.env_version},
    }
    doc.update(_trace_fields())
    if record.exc_info:
        doc["error"] = {"stack_trace": logging.Formatter().formatException(record.exc_info)}
    return doc


class QueueHandler(logging.Handler):
    def emit(self, record: logging.LogRecord) -> None:
        try:
            doc = _record_to_doc(record)
            if _mongo_q is not None:
                try:
                    _mongo_q.put_nowait(doc)
                except asyncio.QueueFull:
                    pass
            if _es_q is not None:
                try:
                    _es_q.put_nowait(dict(doc))
                except asyncio.QueueFull:
                    pass
        except Exception:  # noqa: BLE001
            pass


async def _drain_mongo() -> None:
    assert _mongo_q is not None and _mongo_client is not None
    coll = _mongo_client[settings.mongo_log_db][settings.service_name]
    while True:
        try:
            batch: list[dict] = []
            try:
                batch.append(await asyncio.wait_for(_mongo_q.get(), timeout=_DRAIN_INTERVAL_S))
            except asyncio.TimeoutError:
                pass
            while not _mongo_q.empty() and len(batch) < _BATCH:
                batch.append(_mongo_q.get_nowait())
            if not batch:
                continue
            try:
                await asyncio.to_thread(coll.insert_many, batch, ordered=False)
            except Exception:  # noqa: BLE001
                pass
        except asyncio.CancelledError:
            return


async def _drain_es() -> None:
    assert _es_q is not None and _es_client is not None
    index = f"logs-app-{settings.service_name}-default"
    bulk_url = f"{settings.elastic_search_url}/_bulk"
    while True:
        try:
            batch: list[dict] = []
            try:
                batch.append(await asyncio.wait_for(_es_q.get(), timeout=_DRAIN_INTERVAL_S))
            except asyncio.TimeoutError:
                pass
            while not _es_q.empty() and len(batch) < _BATCH:
                batch.append(_es_q.get_nowait())
            if not batch:
                continue
            lines: list[str] = []
            for d in batch:
                d.pop("_id", None)
                lines.append(json.dumps({"create": {"_index": index}}))
                lines.append(json.dumps(d, ensure_ascii=False))
            body = ("\n".join(lines) + "\n").encode("utf-8")
            try:
                await _es_client.post(bulk_url, content=body,
                                      headers={"content-type": "application/x-ndjson"})
            except Exception:  # noqa: BLE001
                pass
        except asyncio.CancelledError:
            return


def start_mongo_sink() -> None:
    global _mongo_q, _mongo_client, _mongo_task
    if not settings.mongo_log_uri:
        return
    try:
        _mongo_client = MongoClient(settings.mongo_log_uri, serverSelectionTimeoutMS=3000)
    except Exception:  # noqa: BLE001
        _mongo_client = None
        return
    _mongo_q = asyncio.Queue(maxsize=_MAX_QUEUE)
    _mongo_task = asyncio.create_task(_drain_mongo())


def start_es_sink() -> None:
    global _es_q, _es_client, _es_task
    if not settings.elastic_search_url:
        return
    auth = (
        (settings.elastic_search_username, settings.elastic_search_password)
        if settings.elastic_search_username else None
    )
    _es_client = httpx.AsyncClient(timeout=httpx.Timeout(3.0), auth=auth, verify=False)
    _es_q = asyncio.Queue(maxsize=_MAX_QUEUE)
    _es_task = asyncio.create_task(_drain_es())


async def stop_mongo_sink() -> None:
    global _mongo_task, _mongo_client
    if _mongo_task is not None:
        _mongo_task.cancel()
        try:
            await _mongo_task
        except asyncio.CancelledError:
            pass
        _mongo_task = None
    if _mongo_client is not None:
        _mongo_client.close()
        _mongo_client = None


async def stop_es_sink() -> None:
    global _es_task, _es_client
    if _es_task is not None:
        _es_task.cancel()
        try:
            await _es_task
        except asyncio.CancelledError:
            pass
        _es_task = None
    if _es_client is not None:
        await _es_client.aclose()
        _es_client = None


def configure() -> None:
    handler_stdout = logging.StreamHandler(sys.stdout)
    handler_stdout.setFormatter(PrettyJsonFormatter())
    handler_queue = QueueHandler()
    handler_queue.setLevel(logging.INFO)
    level = getattr(logging, settings.log_level.upper(), logging.INFO)
    root = logging.getLogger()
    root.handlers.clear()
    root.setLevel(level)
    root.addHandler(handler_stdout)
    root.addHandler(handler_queue)
    for name in ("httpx", "httpcore", "pymongo", "elasticapm.transport",
                 "elasticapm.transport.http", "uvicorn.access"):
        logging.getLogger(name).setLevel(logging.WARNING)
    logging.getLogger("aiokafka.cluster").setLevel(logging.CRITICAL)


def mongo_health() -> bool:
    if _mongo_client is None:
        return False
    try:
        _mongo_client.admin.command("ping")
        return True
    except Exception:  # noqa: BLE001
        return False
