"""Structured JSON logging — three concurrent sinks, all non-blocking.

  - **stdout**  : JSON lines visible via `docker logs` / `kubectl logs`
                  during local dev and incident response. Live-tail only;
                  not shipped onward by any host-side collector.
  - **MongoDB** : durable analytics store (`dokandar_logs.auth`). Optimised
                  for ad-hoc aggregation queries weeks/months after the fact.
  - **Elasticsearch** : ECS-shaped documents in `logs-app-auth-*`. Drives
                  the Kibana → Discover / Logs sidebar via a direct
                  in-process `_bulk` POST — no shipper required. Carries
                  the APM `trace.id` on every line so the Kibana "Logs"
                  tab on each transaction works.

All three are **fire-and-forget**: a bounded asyncio queue plus a background
drainer per sink. Logging never blocks a request; if a sink is unreachable
or its queue fills, lines are dropped silently — the only effect on the
running service is a missed line in the dashboard, never a hung request.
"""
from __future__ import annotations
import asyncio
import logging
import os
from datetime import datetime, timezone
from typing import Optional

import httpx
from pymongo import MongoClient
from pythonjsonlogger import jsonlogger

from app.config import settings


# ---- shared queues + drainer tasks -----------------------------------------

_mongo_client: Optional[MongoClient] = None
_mongo_queue:  Optional[asyncio.Queue] = None
_mongo_task:   Optional[asyncio.Task] = None

_es_client: Optional[httpx.AsyncClient] = None
_es_queue:  Optional[asyncio.Queue] = None
_es_task:   Optional[asyncio.Task] = None


def _base_payload(record: logging.LogRecord) -> dict:
    """Common shape — superset of ECS so both Mongo and ES can index it."""
    return {
        # canonical timestamp (ECS uses @timestamp; Mongo uses ts)
        "@timestamp": datetime.fromtimestamp(record.created, tz=timezone.utc).isoformat(),
        "ts":         record.created,
        "log": {
            "level":  record.levelname,
            "logger": record.name,
        },
        "message": record.getMessage(),
        "service": {
            "name":        settings.service_name,
            "environment": settings.app_env,
            "version":     settings.code_version,
        },
        # set by the APM agent's logging filter — carries the active trace/transaction
        "trace":       {"id": getattr(record, "elasticapm_trace_id",       None)},
        "transaction": {"id": getattr(record, "elasticapm_transaction_id", None)},
        "span":        {"id": getattr(record, "elasticapm_span_id",        None)},
        "host":        {"name": os.uname().nodename},
    }


# ---- sinks: one Handler per sink, both push into their own queue -----------

class _MongoHandler(logging.Handler):
    def emit(self, record):
        try:
            if _mongo_queue is None:
                return
            try:
                _mongo_queue.put_nowait(_base_payload(record))
            except asyncio.QueueFull:
                pass
        except Exception:
            pass


class _ESHandler(logging.Handler):
    def emit(self, record):
        try:
            if _es_queue is None:
                return
            try:
                _es_queue.put_nowait(_base_payload(record))
            except asyncio.QueueFull:
                pass
        except Exception:
            pass


# ---- drainers --------------------------------------------------------------

async def _drain_mongo():
    assert _mongo_client is not None and _mongo_queue is not None
    coll = _mongo_client[settings.mongo_log_db][settings.service_name]
    while True:
        batch = [await _mongo_queue.get()]
        while not _mongo_queue.empty() and len(batch) < 200:
            batch.append(_mongo_queue.get_nowait())
        try:
            coll.insert_many(batch, ordered=False)
        except Exception:
            pass


async def _drain_es():
    """Bulk-POST to ES `_bulk`. Uses a data-stream-style index name
    (`logs-app-auth-default`) which Elastic auto-rolls daily."""
    assert _es_client is not None and _es_queue is not None
    index = f"logs-app-{settings.service_name}-default"
    while True:
        batch = [await _es_queue.get()]
        while not _es_queue.empty() and len(batch) < 200:
            batch.append(_es_queue.get_nowait())
        # NDJSON: alternate action + document lines
        lines = []
        for doc in batch:
            lines.append('{"create":{}}\n')
            import json as _json
            lines.append(_json.dumps(doc, default=str) + "\n")
        try:
            await _es_client.post(
                f"/{index}/_bulk",
                content="".join(lines).encode("utf-8"),
                headers={"Content-Type": "application/x-ndjson"},
                timeout=5.0,
            )
        except Exception:
            pass


# ---- public API used by main.lifespan -------------------------------------

class PrettyJsonFormatter(jsonlogger.JsonFormatter):
    """Indented JSON for stdout, with the null `elasticapm_*` fields
    stripped before serialization.

    The APM logging filter stamps every record with the active trace /
    transaction / span IDs so logs can be joined to traces in Kibana —
    a powerful feature for logs emitted *inside* an HTTP request. But
    for startup / shutdown / background-task logs, those fields are all
    `null` and produce a wall of noise when pretty-printed. Strip them
    here. Mongo and ES sinks use `_base_payload()` directly (not this
    formatter), so their docs retain the full trace context for joining.
    """

    _APM_KEYS = (
        "elasticapm_transaction_id",
        "elasticapm_trace_id",
        "elasticapm_span_id",
        "elasticapm_service_name",
        "elasticapm_service_environment",
        "elasticapm_labels",
    )

    def add_fields(self, log_record, record, message_dict):
        super().add_fields(log_record, record, message_dict)
        # When there's no active transaction (no `elasticapm_trace_id`),
        # all of the APM-stamped fields are decorative — strip the
        # whole block to keep stdout terse. When there IS a trace, keep
        # the populated fields; that's the actual correlation value.
        trace_id = log_record.get("elasticapm_trace_id")
        if not trace_id:
            for k in self._APM_KEYS:
                log_record.pop(k, None)
            return
        # In a transaction: drop only the individually-null pieces.
        for k in self._APM_KEYS:
            v = log_record.get(k)
            if v in (None, "", {}, []):
                log_record.pop(k, None)


def configure():
    """Idempotent setup. Call once at app startup BEFORE other modules log."""
    level = settings.log_level.upper()
    json_fmt = PrettyJsonFormatter(
        fmt="%(asctime)s %(name)s %(levelname)s %(message)s",
        json_indent=2,
    )
    stdout_h = logging.StreamHandler()
    stdout_h.setFormatter(json_fmt)
    root = logging.getLogger()
    root.handlers.clear()
    root.setLevel(level)
    root.addHandler(stdout_h)
    root.addHandler(_MongoHandler())
    if settings.elastic_search_url:
        root.addHandler(_ESHandler())

    # Silence loggers that would otherwise cause a feedback loop with the
    # ES sink: httpx logs every outbound POST → including our own _bulk POST
    # → which becomes a log line shipped to ES → which causes another POST.
    # Without this, the index inflates by ~one doc per shipped line.
    # `pymongo` similarly logs every write under DEBUG. `elasticapm.transport`
    # also chats at INFO when API_REQUEST_TIME debug is on.
    for noisy in ("httpx", "httpcore", "pymongo", "elasticapm.transport",
                  "elasticapm.transport.http"):
        logging.getLogger(noisy).setLevel(logging.WARNING)

    # Uvicorn's own loggers (startup banner + the access log) default to a
    # timestamp-less "INFO:     ..." line, so `docker logs` doesn't show WHEN a
    # request happened. Prepend a timestamp:
    #   02-06-2026 09:40:03    INFO:     172.17.0.1:.. - "GET /.. HTTP/1.1" 200 OK
    # We keep these on stdout (their own handler, not propagated to root) so the
    # high-volume access lines aren't shipped to Mongo/ES.
    try:
        from uvicorn.logging import AccessFormatter, DefaultFormatter
        _datefmt = "%d-%m-%Y %H:%M:%S"
        _uv_default = DefaultFormatter("%(asctime)s    %(levelprefix)s %(message)s", datefmt=_datefmt)
        _uv_access = AccessFormatter(
            '%(asctime)s    %(client_addr)s - "%(request_line)s" %(status_code)s',
            datefmt=_datefmt,
        )
        for _name, _fmt in (("uvicorn", _uv_default),
                            ("uvicorn.error", _uv_default),
                            ("uvicorn.access", _uv_access)):
            _lg = logging.getLogger(_name)
            if not _lg.handlers:
                _lg.addHandler(logging.StreamHandler())
                _lg.propagate = False
            for _h in _lg.handlers:
                _h.setFormatter(_fmt)
    except Exception:
        pass  # never let log-format tweaking break startup


async def start_mongo_sink():
    """Initialise Mongo connection + drain task. Call from FastAPI lifespan."""
    global _mongo_client, _mongo_queue, _mongo_task
    if _mongo_client is not None:
        return
    _mongo_client = MongoClient(settings.mongo_log_uri, serverSelectionTimeoutMS=3000)
    _mongo_queue = asyncio.Queue(maxsize=10_000)
    _mongo_task = asyncio.create_task(_drain_mongo(), name="mongo-log-drain")


async def start_es_sink():
    """Initialise the ES log shipper. No-op if ELASTIC_SEARCH_URL is unset."""
    global _es_client, _es_queue, _es_task
    if _es_client is not None or not settings.elastic_search_url:
        return
    auth = None
    if settings.elastic_search_username and settings.elastic_search_password:
        auth = (settings.elastic_search_username, settings.elastic_search_password)
    _es_client = httpx.AsyncClient(
        base_url=settings.elastic_search_url.rstrip("/"),
        auth=auth,
        # verify TLS everywhere except dev. dev ES is plain http so this is inert
        # there; it prevents shipping logs over an unverified TLS connection if
        # ELASTIC_SEARCH_URL is ever an https endpoint in stage/prod.
        verify=(settings.app_env != "dev"),
    )
    _es_queue = asyncio.Queue(maxsize=10_000)
    _es_task = asyncio.create_task(_drain_es(), name="es-log-drain")


async def stop_mongo_sink():
    global _mongo_task, _mongo_client
    if _mongo_task:
        _mongo_task.cancel()
        try:
            await _mongo_task
        except (asyncio.CancelledError, Exception):
            pass
    if _mongo_client:
        _mongo_client.close()
    _mongo_task = None
    _mongo_client = None


async def stop_es_sink():
    global _es_task, _es_client
    if _es_task:
        _es_task.cancel()
        try:
            await _es_task
        except (asyncio.CancelledError, Exception):
            pass
    if _es_client:
        await _es_client.aclose()
    _es_task = None
    _es_client = None


def mongo_health() -> bool:
    if _mongo_client is None:
        return False
    try:
        _mongo_client.admin.command("ping")
        return True
    except Exception:
        return False
