"""Standard operational endpoints: /ready /health /data /metrics.

Design notes
------------

`/ready` is the **load-balancer gate**: 200 if and only if every dependency
that's actually required to **handle traffic and run the service correctly
right now** is reachable; 503 otherwise. The probed set is intentionally
SMALL and depends on configuration:

  * **postgres** — always required. Every business endpoint reads or
    writes one of `users`, `refresh_tokens`, or `outbox`.
  * **redis** — only when `OTP_ENABLED=true`. The OTP store + per-phone
    rate limit live in Redis; the `/request` endpoints short-circuit when
    OTP is disabled (see `app/api/v1/auth.py`), so Redis genuinely
    isn't needed for traffic in that mode.

Deliberately NOT in `/ready` (they live on `/health` for diagnostics):

  * **kafka**     — auth uses the outbox pattern. Events buffer in PG
                    and replay on broker recovery; no request blocks on it.
  * **rabbitmq**  — OTP SMS enqueue is best-effort (try/except in
                    `_send_otp`); the request still returns 202.
  * **mongo_logs**, **apm** — fire-and-forget telemetry sinks; the
                    logging design (`app/observability/logging.py`)
                    silently drops on unreachable sinks rather than
                    blocking a request.

If those four are down, the right operator signal is an **alert** on
their `/health` check or on metrics (e.g. `auth_outbox_pending`) — not
a flipped traffic gate.

APM
~~~

Every `_check_*` is async and wrapped in `elasticapm.async_capture_span`,
so the dependency probes show up as named child spans
(`dep.<name>`) under whichever transaction is currently running:

  * `GET /ready`   → 1 or 2 dep spans (postgres + maybe redis)
  * `GET /health`  → 6 dep spans (the full picture, for APM)

Sync underlying clients (kafka via librdkafka, mongo via pymongo, apm
via raw TCP) do their blocking work via `asyncio.to_thread` **from
inside** the async wrapper, so the APM span is created and attached on
the event-loop thread where the transaction contextvar lives. Wrapping
the to_thread call on the outside would put the span in the worker
thread where there's no transaction in scope, and the span would silently
detach.
"""
from __future__ import annotations
import asyncio
import json
import time
from pathlib import Path

import elasticapm
from fastapi import APIRouter, Response, status
from sqlalchemy import text

from app.config import settings
from app.db.session import engine
from app.domain.otp import get_redis
from app.messaging import kafka as kafka_mod, rabbitmq as rmq_mod
from app.observability import apm as apm_mod
from app.observability.logging import mongo_health
from app.storage import s3 as s3_mod


router = APIRouter()
_BOOT_TS = time.time()
_DATA_DIR = Path(__file__).resolve().parents[2] / "data"


# ---------------------------------------------------------------------------
# Identity — one source of truth, used by both /ready and /health.
# ---------------------------------------------------------------------------

def _identity_block() -> dict:
    return {
        "service_name":   settings.service_name,
        "code_version":   settings.code_version,
        "env_version":    settings.env_version,
        "tenant":         settings.tenant,
        "env":            settings.app_env,
        "uptime_seconds": int(time.time() - _BOOT_TS),
    }


# ---------------------------------------------------------------------------
# Dependency probes — each is async and wrapped in an APM span so dependency
# checks appear as labeled spans (`dep.<name>`) in Kibana APM. Returns
# (reachable: bool, latency_ms: float, detail: str).
# ---------------------------------------------------------------------------

# Each dep.* span carries an `extra={"destination": {"service": {...}}}`
# block so Kibana APM lists it in **Service → Dependencies**. The fields:
#   destination.service.name     — short identifier
#   destination.service.type     — span type (db / cache / messaging / external)
#   destination.service.resource — what Kibana groups by (one row per resource)
# `dep.apm` deliberately has NO destination — telling Kibana that auth depends
# on apm-server would draw a self-loop in the Service Map (apm-server IS the
# trace destination). The probe still runs and the span still appears in the
# per-transaction view; it just doesn't register as a graphed dependency.


async def _check_postgres() -> tuple[bool, float, str]:
    async with elasticapm.async_capture_span(
        "dep.postgres", span_type="db", span_subtype="postgresql",
        extra={"destination": {"service": {"name": "postgres", "type": "db", "resource": "postgres"}}},
    ):
        t = time.perf_counter()
        try:
            async with engine.connect() as conn:
                await conn.execute(text("SELECT 1"))
            return True, (time.perf_counter() - t) * 1000, "ok"
        except Exception as e:
            return False, (time.perf_counter() - t) * 1000, str(e)[:80]


async def _check_redis() -> tuple[bool, float, str]:
    async with elasticapm.async_capture_span(
        "dep.redis", span_type="cache", span_subtype="redis",
        extra={"destination": {"service": {"name": "redis", "type": "cache", "resource": "redis"}}},
    ):
        t = time.perf_counter()
        try:
            r = get_redis()
            pong = await r.ping()
            return bool(pong), (time.perf_counter() - t) * 1000, "PONG" if pong else "no-pong"
        except Exception as e:
            return False, (time.perf_counter() - t) * 1000, str(e)[:80]


async def _check_rabbitmq() -> tuple[bool, float, str]:
    async with elasticapm.async_capture_span(
        "dep.rabbitmq", span_type="messaging", span_subtype="rabbitmq",
        extra={"destination": {"service": {"name": "rabbitmq", "type": "messaging", "resource": "rabbitmq"}}},
    ):
        t = time.perf_counter()
        ok = await rmq_mod.health_check()
        return ok, (time.perf_counter() - t) * 1000, "channel-open" if ok else "unreachable"


async def _check_kafka() -> tuple[bool, float, str]:
    async with elasticapm.async_capture_span(
        "dep.kafka", span_type="messaging", span_subtype="kafka",
        extra={"destination": {"service": {"name": "kafka", "type": "messaging", "resource": "kafka"}}},
    ):
        t = time.perf_counter()
        ok = await asyncio.to_thread(kafka_mod.health_check)
        return ok, (time.perf_counter() - t) * 1000, "metadata-ok" if ok else "unreachable"


async def _check_mongo() -> tuple[bool, float, str]:
    async with elasticapm.async_capture_span(
        "dep.mongo_logs", span_type="db", span_subtype="mongodb",
        extra={"destination": {"service": {"name": "mongodb", "type": "db", "resource": "mongodb"}}},
    ):
        t = time.perf_counter()
        ok = await asyncio.to_thread(mongo_health)
        return ok, (time.perf_counter() - t) * 1000, "ping-ok" if ok else "unreachable"


async def _check_apm() -> tuple[bool, float, str]:
    # NB: no destination — see top-of-block comment. Keeping the span name
    # `dep.apm` so it appears alongside the others in the per-transaction
    # span list; it just doesn't graph as an outgoing dependency.
    async with elasticapm.async_capture_span("dep.apm", span_type="external", span_subtype="apm"):
        t = time.perf_counter()
        ok, detail = await asyncio.to_thread(apm_mod.health_check)
        return ok, (time.perf_counter() - t) * 1000, detail


async def _check_s3_kyc() -> tuple[bool, float, str]:
    """HeadBucket the KYC bucket on RustFS. Backs /health.checks.s3_kyc.

    The bucket itself is created on first boot (lifecycle.ensure_db calls
    s3.ensure_bucket); after that this probe is a single HEAD request.
    """
    async with elasticapm.async_capture_span(
        "dep.s3_kyc", span_type="storage", span_subtype="s3",
        extra={"destination": {"service": {"name": "rustfs", "type": "storage", "resource": "rustfs"}}},
    ):
        t = time.perf_counter()
        ok, detail = await s3_mod.check_s3()
        return ok, (time.perf_counter() - t) * 1000, detail


# ---------------------------------------------------------------------------
# Probe orchestrators — one for /ready (traffic-gating set, conditional),
# one for /health (everything, for diagnostics).
# ---------------------------------------------------------------------------

async def _probe_traffic_gating() -> list[dict]:
    """Probe ONLY the deps required to handle traffic and run the service.

    Always: postgres.
    Conditional: redis (only when OTP_ENABLED is on — when off, the
    /request endpoints short-circuit before touching Redis, so Redis
    isn't needed to serve traffic).
    """
    coros = [_check_postgres()]
    include_redis = settings.otp_enabled
    if include_redis:
        coros.append(_check_redis())
    results = await asyncio.gather(*coros)

    deps: list[dict] = [{
        "name": "postgres",
        "reachable": results[0][0],
        "latency_ms": round(results[0][1], 1),
    }]
    if include_redis:
        deps.append({
            "name": "redis",
            "reachable": results[1][0],
            "latency_ms": round(results[1][1], 1),
        })
    return deps


async def _probe_all() -> dict:
    """Probe all seven deps in parallel. Used by /health for full diagnostics.

    Seven dep checks: postgres, redis, kafka, rabbitmq, mongo_logs, apm, s3_kyc.
    """
    pg, redis_ok, rmq, mongo, kafka, apm, s3 = await asyncio.gather(
        _check_postgres(), _check_redis(), _check_rabbitmq(),
        _check_mongo(),    _check_kafka(), _check_apm(), _check_s3_kyc(),
    )
    return {
        "postgres":   {"ok": pg[0],       "detail": pg[2]},
        "redis":      {"ok": redis_ok[0], "detail": redis_ok[2]},
        "kafka":      {"ok": kafka[0],    "detail": kafka[2]},
        "rabbitmq":   {"ok": rmq[0],      "detail": rmq[2]},
        "mongo_logs": {"ok": mongo[0],    "detail": mongo[2]},
        "apm":        {"ok": apm[0],      "detail": apm[2]},
        "s3_kyc":     {"ok": s3[0],       "detail": s3[2]},
    }


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@router.get("/ready", tags=["ops"], operation_id="getReady", summary="Readiness probe (traffic-gating deps)")
async def ready(response: Response):
    """Readiness probe — the LB's single source of truth.

    Body shape: ``{status, identity, dependencies}``.

      * `status`       — "ready" / "not_ready", mirrors HTTP 200 vs 503
      * `identity`     — service_name, code_version, env_version, tenant,
                          env, uptime_seconds (build/runtime fingerprint)
      * `dependencies` — only the traffic-gating set (postgres always;
                          redis when OTP_ENABLED=true)

    Diagnostic dependencies (kafka, rabbitmq, mongo_logs, apm) live on
    `/health`, not here.
    """
    deps = await _probe_traffic_gating()
    all_ok = all(d["reachable"] for d in deps)
    if not all_ok:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    return {
        "status": "ready" if all_ok else "not_ready",
        "identity": _identity_block(),
        "dependencies": deps,
    }


@router.get("/health", tags=["ops"], operation_id="getHealth", summary="Full health + dependency diagnostics")
async def health(response: Response):
    """Liveness probe + full diagnostics.

    Same six dependencies as before — postgres, redis, kafka, rabbitmq,
    mongo_logs, apm — each with a human-readable detail string. Carries
    the same `identity` block as `/ready`, plus an `observability` block
    showing where this instance ships traces and analytical logs. This
    is the **diagnostic** surface; the load balancer should gate on
    `/ready`, not `/health`.
    """
    checks = await _probe_all()
    healthy = all(v["ok"] for v in checks.values())
    if not healthy:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    return {
        "status": "healthy" if healthy else "unhealthy",
        "identity": _identity_block(),
        "checks": checks,
        "observability": {
            "apm_service_name": settings.apm_service_name,
            "apm_server_url":   settings.apm_server_url,
            "logs_sink_mongo":  f"mongodb://{settings.mongo_log_db}/{settings.service_name}",
            "logs_sink_es":     f"{settings.elastic_search_url.rstrip('/')}/logs-app-{settings.service_name}-*" if settings.elastic_search_url else "disabled",
        },
    }


@router.get("/data", tags=["ops"], operation_id="getData", summary="Tenant introspection snapshot")
async def data_endpoint(response: Response):
    """Returns data/<tenant>/result.json — the tenant introspection snapshot."""
    tenant = settings.tenant
    f = _DATA_DIR / tenant / "result.json"
    if not f.exists():
        response.status_code = status.HTTP_404_NOT_FOUND
        return {"error": {"code": "no_snapshot", "message": f"data/{tenant}/result.json not present (run data/{tenant}/collect.sh)"}}
    try:
        snapshot = json.loads(f.read_text())
    except Exception as e:
        response.status_code = status.HTTP_500_INTERNAL_SERVER_ERROR
        return {"error": {"code": "snapshot_parse_failed", "message": str(e)}}
    # identity block first, then the collect.sh snapshot fields
    return {"identity": _identity_block(), **snapshot}
