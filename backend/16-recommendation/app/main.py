from __future__ import annotations
import asyncio, json, logging, uuid
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
from app.db import qdrant as qdrant_db, redis as redis_cache
from app.grpc import server as grpc_server
from app.messaging import projectors
from app.observability import apm as apm_mod
from app.observability import logging as obs_logging
from app.ops.routes import router as ops_router
from app.reco.router import router as reco_router


class PrettyJSONResponse(JSONResponse):
    media_type = "application/json"
    def render(self, content: Any) -> bytes:
        return (json.dumps(content, indent=2, ensure_ascii=False, default=str,
                           sort_keys=False, separators=(",", ": ")) + "\n").encode("utf-8")


log = logging.getLogger("reco.main")


@asynccontextmanager
async def lifespan(app):
    obs_logging.configure(); obs_logging.start_mongo_sink(); obs_logging.start_es_sink()
    try: await pg_connect()
    except Exception: log.exception("PG fail")
    try: await qdrant_db.connect()          # degradable — ANN falls back to popularity
    except Exception: log.exception("qdrant fail")
    try: await redis_cache.connect()        # degradable — feed cache
    except Exception: log.exception("redis fail")
    try: await projectors.start_all()
    except Exception: log.exception("projectors fail")
    grpc_task = asyncio.create_task(grpc_server.serve())   # feed-serving @ GRPC_PORT (sibling task)
    log.warning("[boot] 16-recommendation ready port=%d grpc=%d", settings.service_port, settings.grpc_port)
    try: yield
    finally:
        await grpc_server.stop()
        grpc_task.cancel()
        try: await grpc_task
        except asyncio.CancelledError: pass
        await projectors.stop_all()
        await redis_cache.close(); await qdrant_db.close()
        await pg_disconnect()
        await obs_logging.stop_mongo_sink(); await obs_logging.stop_es_sink()


_DESC = (
    f"**service_name**: `{settings.service_name}` &nbsp;|&nbsp; "
    f"**code_version**: `{settings.code_version}` &nbsp;|&nbsp; "
    f"**env_version**: `{settings.env_version}` &nbsp;|&nbsp; "
    f"**tenant**: `{settings.tenant}` &nbsp;|&nbsp; **env**: `{settings.app_env}`\n\n"
    "### How to test\n"
    "1. Click **Authorize** and paste a Bearer **access token** from the auth service "
    "(`POST /api/v1/auth/login/request` → `/login/verify`). `GET /feed/me` needs any "
    "valid token; `POST /admin/retrain` needs an `admin`/`platform_staff` token.\n"
    "2. `GET /similar/{product_id}` and `GET /cross-sell` are **public reads** — no token "
    "required. Pass a catalog product **UUID**.\n"
    "3. `size` is clamped to `1..100`. Feeds degrade gracefully to a popularity / cold-start "
    "source when ANN embeddings are unavailable (still `200`, see `source`).\n"
    "4. Errors use the platform envelope "
    "`{error:{code,message,request_id,details}}` with lowercase_snake codes."
)


def create_app() -> FastAPI:
    app = FastAPI(title="DOKANDAR Recommendation Service", version=settings.code_version,
                  description=_DESC,
                  docs_url=None, redoc_url=None, openapi_url="/openapi.json",
                  default_response_class=PrettyJSONResponse, lifespan=lifespan)

    @app.get("/docs", include_in_schema=False)
    async def _docs():
        return get_swagger_ui_html(
            openapi_url=app.openapi_url, title="16-recommendation API",
            swagger_ui_parameters={"persistAuthorization": True})

    @app.middleware("http")
    async def rid(req, cn):
        import time
        r = req.headers.get("x-request-id") or uuid.uuid4().hex
        req.state.request_id = r
        t0 = time.perf_counter()
        resp = await cn(req)
        resp.headers["x-request-id"] = r
        # Structured access log (§11) — one line per genuine request, trace-correlated
        # (runs inside the APM transaction). Excludes /ready,/metrics,/health. Templated
        # route only — NO user_id / NO body / NO raw feed.
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

    app.include_router(ops_router); app.include_router(reco_router)

    Instrumentator(should_group_status_codes=True, should_ignore_untemplated=True,
                   excluded_handlers=["/metrics","/ready","/health"]).instrument(app).expose(
        app, include_in_schema=False, endpoint="/metrics_promfast")

    _TAGS = [
        {"name": "recommendation",
         "description": "Personalised feed, similar-products and cross-sell reads, plus the "
                        "admin retrain trigger."},
        {"name": "ops",
         "description": "Platform contract endpoints: /ready /health /data /metrics."},
    ]

    def _o():
        if app.openapi_schema: return app.openapi_schema
        s = get_openapi(
            title=app.title, version=app.version, routes=app.routes,
            description=app.description, tags=_TAGS,
            contact={"name": "DOKANDAR Platform", "url": "https://dokandar.com.bd",
                     "email": "api@dokandar.com.bd"},
            license_info={"name": "Proprietary"},
            servers=[{"url": "https://api.dokandar.com.bd", "description": "prod"},
                     {"url": "http://localhost:10016", "description": "local"}],
        )
        # Standardise the security scheme name to `bearerJwt` (doc-only; runtime auth is the
        # Depends, untouched). FastAPI auto-emits the scheme + per-op refs as `HTTPBearer`.
        comps = s.setdefault("components", {})
        schemes = comps.setdefault("securitySchemes", {})
        schemes.pop("HTTPBearer", None)
        schemes["bearerJwt"] = {"type": "http", "scheme": "bearer", "bearerFormat": "JWT"}
        for _path in s.get("paths", {}).values():
            if not isinstance(_path, dict):
                continue
            for _op in _path.values():
                if not isinstance(_op, dict) or "security" not in _op:
                    continue
                new_sec = []
                for req in _op["security"]:
                    if isinstance(req, dict) and "HTTPBearer" in req:
                        req = {"bearerJwt": req["HTTPBearer"]}
                    new_sec.append(req)
                _op["security"] = new_sec
        app.openapi_schema = s
        return s

    app.openapi = _o
    apm_mod.install(app)
    return app


app = create_app()
