"""REST surface (SA §13.5 adapted to the DM command table): fleet envelope
{success,data,error,meta}, problem+json errors, Idempotency-Key on unsafe writes."""

from __future__ import annotations

import json
import logging
import os
from typing import Any

import anyio.to_thread
from fastapi import FastAPI, Header, Request, Response
from fastapi.responses import JSONResponse

from fraud import service as svc
from fraud.config import Config

log = logging.getLogger("fraud.api")

MAX_BODY_BYTES = 256 * 1024


def envelope(data: Any, meta: dict[str, Any] | None = None) -> dict[str, Any]:
    return {"success": True, "data": data, "error": None, "meta": meta}


def problem(status: int, code: str, detail: str) -> JSONResponse:
    return JSONResponse(
        status_code=status,
        media_type="application/problem+json",
        content={"type": "about:blank", "title": code.rsplit(".", 1)[-1], "status": status,
                 "code": code, "detail": detail},
    )


def build_app(cfg: Config, fraud: svc.FraudService, profile_reader: Any,
              health_probe: Any) -> FastAPI:
    app = FastAPI(title="DOKANDAR fraud-svc", version="v1",
                  docs_url="/docs", openapi_url="/swagger/v1/swagger.json")

    @app.exception_handler(svc.ApiError)
    async def _api_error(_req: Request, e: svc.ApiError) -> JSONResponse:
        return problem(e.status, e.code, e.message)

    async def body_of(request: Request) -> dict[str, Any]:
        raw = await request.body()
        if len(raw) > MAX_BODY_BYTES:
            raise svc.ApiError(413, "dokandar.fraud.request.too_large", "body exceeds 256KB")
        if not raw:
            return {}
        try:
            loaded = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise svc.ApiError(400, "dokandar.fraud.request.malformed",
                               "body must be JSON") from exc
        if not isinstance(loaded, dict):
            raise svc.ApiError(400, "dokandar.fraud.request.malformed", "body must be an object")
        return loaded

    @app.post("/v1/fraud/signals", status_code=201)
    async def raise_signal(request: Request, response: Response,
                           idempotency_key: str | None = Header(default=None)) -> dict[str, Any]:
        body = await body_of(request)
        status, data, replayed = await anyio.to_thread.run_sync(
            lambda: fraud.run_idempotent(
                idempotency_key, "POST /v1/fraud/signals", body, 201,
            lambda cx: fraud.raise_signal(
                cx, str(body.get("subjectDid", "")), str(body.get("reason", "")),
                float(body["riskScore"]) if isinstance(body.get("riskScore"), int | float)
                else -1.0,
                svc.parse_evidence(body.get("evidence")), str(body.get("raisedBy", "")))))
        response.status_code = status
        return envelope(data, {"replayed": replayed})

    @app.post("/v1/fraud/holds", status_code=202)
    async def hold_account(request: Request, response: Response,
                           idempotency_key: str | None = Header(default=None)) -> dict[str, Any]:
        body = await body_of(request)
        status, data, replayed = await anyio.to_thread.run_sync(
            lambda: fraud.run_idempotent(
                idempotency_key, "POST /v1/fraud/holds", body, 202,
            lambda cx: fraud.hold_account(
                cx, str(body.get("subjectDid", "")), str(body.get("reason", "")),
                str(body.get("approver1", "")), svc.parse_evidence(body.get("evidence")))))
        response.status_code = status
        return envelope(data, {"replayed": replayed})

    @app.post("/v1/fraud/holds/{subject_did}/approve")
    async def approve_hold(subject_did: str, request: Request, response: Response,
                           idempotency_key: str | None = Header(default=None)) -> dict[str, Any]:
        body = await body_of(request)
        status, data, replayed = await anyio.to_thread.run_sync(
            lambda: fraud.run_idempotent(
                idempotency_key, f"POST /v1/fraud/holds/{subject_did}/approve", body, 200,
                lambda cx: fraud.approve_hold(cx, subject_did, str(body.get("approver2", "")))))
        response.status_code = status
        return envelope(data, {"replayed": replayed})

    @app.post("/v1/fraud/holds/{subject_did}/release")
    async def release_hold(subject_did: str, request: Request, response: Response,
                           idempotency_key: str | None = Header(default=None)) -> dict[str, Any]:
        body = await body_of(request)
        status, data, replayed = await anyio.to_thread.run_sync(
            lambda: fraud.run_idempotent(
                idempotency_key, f"POST /v1/fraud/holds/{subject_did}/release", body, 200,
                lambda cx: fraud.release_hold(cx, subject_did, str(body.get("approver1", "")),
                                              str(body.get("approver2", "")))))
        response.status_code = status
        return envelope(data, {"replayed": replayed})

    @app.get("/v1/fraud/holds/{subject_did}")
    async def get_hold(subject_did: str) -> Any:
        hold = await anyio.to_thread.run_sync(lambda: fraud.get_hold(subject_did))
        if hold is None:
            return problem(404, "dokandar.fraud.hold.not_found", "no hold for subject")
        return envelope(hold)

    @app.get("/v1/fraud/scores/{subject_did}")
    async def get_score(subject_did: str) -> dict[str, Any]:
        return envelope(await anyio.to_thread.run_sync(lambda: profile_reader(subject_did)))

    @app.get("/health")
    @app.get("/live")
    async def health() -> dict[str, Any]:
        # CC-CONS-4: uniform {success,data:{...}} envelope on the probes (was a flat body).
        return envelope({"status": "ok", "service": "fraud-svc", **_build_info(cfg)})

    @app.get("/ready")
    async def ready() -> Any:
        checks = health_probe()
        ok = all(checks.values())
        body = {"status": "ready" if ok else "degraded", **checks}
        if not ok:
            return JSONResponse(status_code=503, content={"success": False, "data": body,
                                                          "error": None, "meta": None})
        return envelope(body)

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
