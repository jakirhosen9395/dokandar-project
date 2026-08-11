"""11-reporting ops — postgres-only gate."""
from __future__ import annotations
import asyncio, json, logging, socket, time
from pathlib import Path
import elasticapm
from fastapi import APIRouter, Response, status
from fastapi.responses import PlainTextResponse
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

from app.config import settings
from app.db.postgres import pool as _pool
from app.observability import apm as apm_mod
from app.observability.logging import mongo_health

log = logging.getLogger("reporting.ops")
router = APIRouter()
_BOOT_TS = time.time()
_DATA_DIR = Path(__file__).resolve().parents[2] / "data"


def _identity():
    return {"service_name": settings.service_name, "code_version": settings.code_version,
            "env_version": settings.env_version, "tenant": settings.tenant,
            "env": settings.app_env, "uptime_seconds": int(time.time() - _BOOT_TS)}


async def _check_pg():
    t0 = time.perf_counter()
    try:
        with elasticapm.async_capture_span("dep.postgres", span_type="db", span_subtype="postgresql"):
            async with _pool().acquire() as c: await c.fetchval("SELECT 1")
        return True, round((time.perf_counter() - t0) * 1000, 2), "ok"
    except Exception as e:
        return False, 0.0, f"err:{type(e).__name__}"


def _tcp(target, default_port):
    try:
        h, _, p = target.partition(":")
        with socket.create_connection((h, int(p or default_port)), timeout=2): return True, "ok"
    except Exception as e: return False, f"err:{type(e).__name__}"


@router.get("/ready", tags=["ops"], operation_id="getReady",
            summary="Readiness gate",
            description="LB/readiness probe. Returns 200 only when Postgres (the system of "
                        "record) is reachable; 503 otherwise. No auth.")
async def ready() -> Response:
    pg = await _check_pg()
    body = {"status": "ready" if pg[0] else "not_ready", "identity": _identity(),
            "dependencies": [{"name":"postgres","reachable":pg[0],"latency_ms":pg[1],"detail":pg[2]}]}
    return _pretty(body, 200 if pg[0] else 503)


@router.get("/health", tags=["ops"], operation_id="getHealth",
            summary="Full diagnostics",
            description="Full dependency diagnostics (postgres, kafka, mongo logs, apm) plus an "
                        "observability block. Diagnostic peers never flip status. No auth.")
async def health() -> Response:
    pg = await _check_pg()
    kf_ok, kf_d = await asyncio.to_thread(_tcp, settings.kafka_bootstrap, 9092)
    mlog = await asyncio.to_thread(mongo_health)
    apm_ok, apm_d = await asyncio.to_thread(apm_mod.health_check)
    checks = {"postgres":{"ok":pg[0],"detail":pg[2]},
              "kafka":{"ok":kf_ok,"detail":kf_d},
              "mongo_logs":{"ok":mlog,"detail":"ok" if mlog else "unreachable"},
              "apm":{"ok":apm_ok,"detail":apm_d}}
    healthy = pg[0] and kf_ok
    return _pretty({"status":"healthy" if healthy else "unhealthy",
                    "identity":_identity(),"checks":checks,
                    "observability":{"apm_service_name":settings.apm_service_name}},
                   200 if healthy else 503)


@router.get("/data", tags=["ops"], operation_id="getData",
            summary="Tenant snapshot",
            description="Identity block prepended to the read-only `data/<tenant>/result.json` "
                        "snapshot. `404 no_snapshot` / `500 snapshot_parse_failed` are contract. No auth.")
async def data() -> Response:
    p = _DATA_DIR / settings.tenant / "result.json"
    if not p.exists():
        return _pretty({"error":{"code":"no_snapshot","message":"no snapshot"}}, 404)
    try:
        snap = json.loads(p.read_text())
        if not isinstance(snap, dict): raise ValueError("not object")
    except Exception:
        return _pretty({"error":{"code":"snapshot_parse_failed","message":"invalid JSON"}}, 500)
    return _pretty({"identity":_identity(),**snap}, 200)


@router.get("/metrics", include_in_schema=False)
async def metrics() -> Response:
    return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)


def _pretty(payload, code):
    b = (json.dumps(payload, indent=2, ensure_ascii=False, default=str,
                    sort_keys=False, separators=(",", ": ")) + "\n").encode("utf-8")
    return Response(content=b, status_code=code, media_type="application/json")
