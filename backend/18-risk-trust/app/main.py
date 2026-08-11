from __future__ import annotations
import asyncio, json, logging, time, uuid
from contextlib import asynccontextmanager
from typing import Any
from fastapi import FastAPI, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.openapi.docs import get_swagger_ui_html
from fastapi.openapi.utils import get_openapi
from fastapi.responses import JSONResponse
from prometheus_fastapi_instrumentator import Instrumentator
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.config import settings
from app.db.postgres import connect as pg_connect, disconnect as pg_disconnect
from app.db import qdrant as qdrant_db
from app.grpc import server as grpc_server
from app.messaging import projectors, outbox_relay
from app.observability import apm as apm_mod
from app.observability import logging as obs_logging
from app.ops.routes import router as ops_router
from app.risk.router import router as risk_router


class PrettyJSONResponse(JSONResponse):
    media_type = "application/json"
    def render(self, content: Any) -> bytes:
        return (json.dumps(content, indent=2, ensure_ascii=False, default=str,
                           sort_keys=False, separators=(",", ": ")) + "\n").encode("utf-8")


log = logging.getLogger("risk.main")


@asynccontextmanager
async def lifespan(app):
    obs_logging.configure(); obs_logging.start_mongo_sink(); obs_logging.start_es_sink()
    try: await pg_connect()
    except Exception: log.exception("PG fail")
    try: await qdrant_db.connect()          # degradable — graph ANN (rule fallback otherwise)
    except Exception: log.exception("qdrant fail")
    try: await projectors.start_all()       # consumes shipment.failed_delivery (the COD label)
    except Exception: log.exception("projectors fail")
    try: await outbox_relay.start()         # risk.* outbox → Kafka
    except Exception: log.exception("relay fail")
    grpc_task = asyncio.create_task(grpc_server.serve())   # Risk.ScoreCheckout|ScoreCOD @ GRPC_PORT
    log.warning("[boot] 18-risk-trust ready port=%d grpc=%d", settings.service_port, settings.grpc_port)
    try: yield
    finally:
        await grpc_server.stop()
        grpc_task.cancel()
        try: await grpc_task
        except asyncio.CancelledError: pass
        await outbox_relay.stop()
        await projectors.stop_all()
        await qdrant_db.close()
        await pg_disconnect()
        await obs_logging.stop_mongo_sink(); await obs_logging.stop_es_sink()


_DESCRIPTION = (
    f"**service_name**: `{settings.service_name}` &nbsp;|&nbsp; "
    f"**code_version**: `{settings.code_version}` &nbsp;|&nbsp; "
    f"**env_version**: `{settings.env_version}` &nbsp;|&nbsp; "
    f"**tenant**: `{settings.tenant}` &nbsp;|&nbsp; "
    f"**env**: `{settings.app_env}`\n\n"
    "Fraud / COD-refusal scoring for the DOKANDAR marketplace. Decisions are returned as "
    "`allow` / `review` / `deny` plus opaque reason codes; the numeric score and thresholds "
    "are never exposed.\n\n"
    "### How to test\n"
    "1. **Scoring** routes (`/score/*`) are east-west internal calls — click **Authorize** and set "
    "the `internalToken` (`x-internal-token`) value to your fleet `INTERNAL_SERVICE_TOKEN`. In local "
    "dev with an empty token they accept unauthenticated requests.\n"
    "2. **Admin** routes (`/admin/*`) need a Bearer **access token** with role `admin`/`platform_staff` "
    "from the auth service (`POST /api/v1/auth/login/request` → `/login/verify`). Click **Authorize** "
    "and set `bearerJwt`.\n"
    "3. Amounts are integer **paisa** (50,000 BDT = 5,000,000). Bodies are pre-filled with working examples."
)


def create_app() -> FastAPI:
    app = FastAPI(title="DOKANDAR Risk & Trust Service", version=settings.code_version,
                  description=_DESCRIPTION,
                  contact={"name": "DOKANDAR Platform", "url": "https://dokandar.com.bd",
                           "email": "api@dokandar.com.bd"},
                  license_info={"name": "Proprietary"},
                  servers=[{"url": "https://api.dokandar.com.bd", "description": "prod"},
                           {"url": "http://localhost:10018", "description": "local"}],
                  docs_url=None, redoc_url=None, openapi_url="/openapi.json",
                  default_response_class=PrettyJSONResponse, lifespan=lifespan)

    @app.middleware("http")
    async def rid(req, cn):
        r = req.headers.get("x-request-id") or uuid.uuid4().hex
        req.state.request_id = r
        t0 = time.perf_counter()
        resp = await cn(req)
        resp.headers["x-request-id"] = r
        # Trace-correlated access log (§11) — exclude /ready,/metrics,/health. Templated
        # route only — NEVER a user_id, device fingerprint, score, or threshold.
        path = req.url.path
        if path not in ("/ready", "/metrics", "/health", "/metrics_promfast"):
            route = req.scope.get("route")
            tmpl = getattr(route, "path", path) if route else path
            log.info("access %s %s %d %.1fms rid=%s", req.method, tmpl, resp.status_code,
                     (time.perf_counter() - t0) * 1000, r)
        return resp

    _CODES = {400:"bad_request",401:"unauthorized",403:"forbidden",404:"not_found",
              405:"method_not_allowed",409:"conflict",422:"invalid_request",500:"internal_error",503:"dep_unavailable"}

    @app.exception_handler(StarletteHTTPException)
    async def http_exc(req, exc):
        if exc.status_code == 404 and not isinstance(exc.detail, dict):
            try:
                import elasticapm
                elasticapm.set_transaction_name(f"{req.method} unmatched", override=True)
            except Exception:
                pass
            return Response(status_code=404)
        if isinstance(exc.detail, dict) and "error" in exc.detail:
            return PrettyJSONResponse(exc.detail, status_code=exc.status_code)
        return PrettyJSONResponse({"error":{"code":_CODES.get(exc.status_code,"error"),
            "message":str(exc.detail),"request_id":getattr(req.state,"request_id",None)}}, status_code=exc.status_code)

    @app.exception_handler(RequestValidationError)
    async def val(req, exc):
        return PrettyJSONResponse({"error":{"code":"invalid_request","message":"validation failed",
            "details":exc.errors(),"request_id":getattr(req.state,"request_id",None)}}, status_code=422)

    app.include_router(ops_router); app.include_router(risk_router)

    @app.get("/docs", include_in_schema=False)
    async def swagger_ui():
        return get_swagger_ui_html(
            openapi_url=app.openapi_url,
            title="18-risk-trust API",
            swagger_ui_parameters={"persistAuthorization": True},
        )

    Instrumentator(should_group_status_codes=True, should_ignore_untemplated=True,
                   excluded_handlers=["/metrics","/ready","/health"]).instrument(app).expose(
        app, include_in_schema=False, endpoint="/metrics_promfast")

    def _o():
        if app.openapi_schema: return app.openapi_schema
        s = get_openapi(title=app.title, version=app.version, routes=app.routes,
                        description=app.description, contact=app.contact,
                        license_info=app.license_info, servers=app.servers,
                        tags=[
                            {"name": "ops", "description": "Operational / contract surface "
                             "(/ready /health /data /metrics)."},
                            {"name": "scoring", "description": "Internal fraud / COD / review "
                             "scoring (east-west, x-internal-token)."},
                            {"name": "admin", "description": "Risk rules & overrides (admin JWT)."},
                        ])
        comps = s.setdefault("components", {})
        sec = comps.setdefault("securitySchemes", {})
        # Standard scheme names. Keep HTTPBearer too so FastAPI-auto refs stay valid.
        sec["bearerJwt"] = {"type": "http", "scheme": "bearer", "bearerFormat": "JWT"}
        sec["HTTPBearer"] = {"type": "http", "scheme": "bearer", "bearerFormat": "JWT"}
        sec["internalToken"] = {"type": "apiKey", "in": "header", "name": "x-internal-token"}
        # Mirror auto-applied HTTPBearer refs onto bearerJwt; document internalToken on /score/*.
        for path, item in s.get("paths", {}).items():
            for method, op in item.items():
                if not isinstance(op, dict):
                    continue
                if op.get("security"):
                    op["security"] = [{"bearerJwt": []}]
                elif path.startswith("/api/v1/risk/score/"):
                    op["security"] = [{"internalToken": []}]
        app.openapi_schema = s
        return s

    app.openapi = _o
    apm_mod.install(app)
    return app


app = create_app()
