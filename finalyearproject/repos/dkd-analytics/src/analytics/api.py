"""Advisory read surface (SA §15.5). Read-only — this service owns no command; every
response body carries the FR-ANL-051 advisory envelope and an asOf watermark (G11)."""

from __future__ import annotations

import json
import logging
import os
from collections.abc import Callable
from typing import Any

import anyio.to_thread
from fastapi import FastAPI
from fastapi.responses import JSONResponse

from analytics import advisory
from analytics.config import Config

log = logging.getLogger("analytics.api")

Queries = Callable[[str, dict[str, Any]], list[dict[str, Any]]]


def envelope(data: Any) -> dict[str, Any]:
    return {"success": True, "data": data, "error": None, "meta": {"asOf": advisory.now_ms()}}


def build_app(cfg: Config, run_query: Queries, health_probe: Callable[[], bool]) -> FastAPI:
    app = FastAPI(title="DOKANDAR analytics-svc", version="v1",
                  docs_url="/docs", openapi_url="/swagger/v1/swagger.json")

    @app.get("/v1/analytics/shortages")
    async def shortages() -> dict[str, Any]:
        def compute() -> list[dict[str, Any]]:
            # Non-transactional advisory snapshot: three FINAL reads may straddle ingests;
            # acceptable for a non-binding view (FR-ANL-042/051), watermarked by meta.asOf.
            window_start = advisory.now_ms() - cfg.demand_window_ms
            supply = run_query(
                "SELECT gpid, sum(quantity) AS supply FROM fact_custody_events FINAL "
                "WHERE event = 'CustodyInitialized' GROUP BY gpid", {})
            recalled = {r["gpid"]: r["n"] for r in run_query(
                "SELECT gpid, count() AS n FROM fact_custody_events FINAL "
                "WHERE event = 'ProductRecalled' GROUP BY gpid", {})}
            demand = {r["gpid"]: int(r["demand"]) for r in run_query(
                "SELECT gpid, sum(quantity) AS demand FROM fact_orders FINAL "
                "WHERE event = 'OrderPlaced' AND gpid != '' "
                "AND occurred_at >= {window_start:Int64} GROUP BY gpid",
                {"window_start": window_start})}
            out = []
            for row in supply:
                gpid = str(row["gpid"])
                if not gpid or gpid in recalled:
                    continue
                d = demand.get(gpid, 0)
                cls = advisory.shortage_class(int(row["supply"]), d)
                if cls is not None:
                    out.append(advisory.envelope(
                        {"gpid": gpid, "supply": int(row["supply"]), "demandWindow": d,
                         "class": cls}, advisory.confidence_for(d)))
            return out
        return envelope(await anyio.to_thread.run_sync(compute))

    @app.get("/v1/analytics/price-hints")
    async def price_hints(gpid: str = "") -> Any:
        def compute() -> Any:
            rows = run_query(
                "SELECT occurred_at, unit_price_poisha FROM fact_trade_orders FINAL "
                "WHERE event = 'TradeOrderCreated' AND unit_price_poisha > 0 "
                + ("AND gpid = {gpid:String} " if gpid else "")
                + "ORDER BY occurred_at DESC LIMIT 200", {"gpid": gpid} if gpid else {})
            hint = advisory.price_hint([(int(r["occurred_at"]), int(r["unit_price_poisha"]))
                                        for r in rows])
            if hint is None:
                return None
            return advisory.envelope({"gpid": gpid or "ALL", **hint, "nonBinding": True},
                                     advisory.confidence_for(hint["sampleSize"]))
        data = await anyio.to_thread.run_sync(compute)
        if data is None:
            return JSONResponse(status_code=404, media_type="application/problem+json",
                                content={"type": "about:blank", "title": "no_data", "status": 404,
                                         "code": "dokandar.analytics.hint.no_data",
                                         "detail": "no priced trades observed yet"})
        return envelope(data)

    @app.get("/v1/analytics/forecasts")
    async def forecasts() -> dict[str, Any]:
        def compute() -> dict[str, Any]:
            rows = run_query(
                "SELECT toDate(occurred_at / 1000) AS day, count() AS n FROM fact_orders FINAL "
                "WHERE event = 'OrderPlaced' GROUP BY day ORDER BY day", {})
            counts = [int(r["n"]) for r in rows]
            fc = advisory.forecast(counts)
            return advisory.envelope({"metric": "daily_orders", **fc},
                                     advisory.confidence_for(len(counts)))
        return envelope(await anyio.to_thread.run_sync(compute))

    # F-10: this endpoint is freshness INTROSPECTION (row-count + watermark), NOT an inference output,
    # so it deliberately carries the STANDARD envelope only — never the advisory envelope
    # (advisory/confidence/model_id), which is reserved for actual advisory inferences. Documented exemption.
    @app.get("/v1/analytics/marts/{mart}/asOf")
    async def mart_as_of(mart: str) -> Any:
        allowed = {"fact_custody_events", "fact_orders", "fact_trade_orders", "fact_settlements",
                   "fact_logistics", "fact_fraud_signals", "dim_product"}
        if mart not in allowed:
            return JSONResponse(status_code=404, media_type="application/problem+json",
                                content={"type": "about:blank", "title": "unknown_mart",
                                         "status": 404,
                                         "code": "dokandar.analytics.mart.unknown",
                                         "detail": f"mart must be one of {sorted(allowed)}"})

        def compute() -> dict[str, Any]:
            rows = run_query(
                f"SELECT count() AS rows, max(ingest_ts) AS as_of FROM {mart} FINAL", {})
            r = rows[0] if rows else {"rows": 0, "as_of": 0}
            return {"mart": mart, "rows": int(r["rows"]), "asOf": int(r["as_of"] or 0)}
        return envelope(await anyio.to_thread.run_sync(compute))

    @app.get("/health")
    @app.get("/live")
    async def health() -> dict[str, Any]:
        # CC-CONS-4: uniform {success,data:{...}} envelope on the probes (was a flat body).
        return envelope({"status": "ok", "service": "analytics-svc", **_build_info(cfg)})

    @app.get("/ready")
    async def ready() -> Any:
        ok = await anyio.to_thread.run_sync(health_probe)
        if not ok:
            return JSONResponse(status_code=503, content={"success": False,
                "data": {"status": "degraded", "clickhouse": False}, "error": None, "meta": None})
        return envelope({"status": "ready", "clickhouse": True})

    @app.get("/version")
    async def version() -> dict[str, Any]:
        return envelope(_build_info(cfg))

    return app


def _build_info(cfg: Config) -> dict[str, Any]:
    if os.path.exists(cfg.build_info_path):
        try:
            with open(cfg.build_info_path) as f:
                loaded = json.load(f)
            if isinstance(loaded, dict):
                return {str(k): v for k, v in loaded.items()}
        except (OSError, json.JSONDecodeError):
            log.warning("build info unreadable at %s", cfg.build_info_path)
    return {"version": "0.0.0-dev", "gitSha": "unknown", "buildTime": "unknown"}
