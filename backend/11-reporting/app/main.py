from __future__ import annotations
import json, logging, uuid
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
from app.messaging import projectors
from app.observability import apm as apm_mod
from app.observability import logging as obs_logging
from app.ops.routes import router as ops_router
from app.reporting.router import router as reporting_router


class PrettyJSONResponse(JSONResponse):
    media_type = "application/json"
    def render(self, content: Any) -> bytes:
        return (json.dumps(content, indent=2, ensure_ascii=False, default=str,
                           sort_keys=False, separators=(",", ": ")) + "\n").encode("utf-8")


log = logging.getLogger("reporting.main")


@asynccontextmanager
async def lifespan(app):
    obs_logging.configure(); obs_logging.start_mongo_sink(); obs_logging.start_es_sink()
    try: await pg_connect()
    except Exception: log.exception("PG fail")
    try: await projectors.start_all()
    except Exception: log.exception("projectors fail")
    log.warning("[boot] 11-reporting ready port=%d", settings.service_port)
    try: yield
    finally:
        await projectors.stop_all()
        await pg_disconnect()
        await obs_logging.stop_mongo_sink(); await obs_logging.stop_es_sink()


_API_DESCRIPTION = (
    f"**service_name**: `{settings.service_name}` &nbsp;|&nbsp; "
    f"**code_version**: `{settings.code_version}` &nbsp;|&nbsp; "
    f"**env_version**: `{settings.env_version}` &nbsp;|&nbsp; "
    f"**tenant**: `{settings.tenant}` &nbsp;|&nbsp; "
    f"**env**: `{settings.app_env}`\n\n"
    "OLAP analytics & regulatory exports for the DOKANDAR marketplace (consumer-only "
    "read projection — no outbox). All money is integer **paisa** (BDT minor units); "
    "dates are ISO-8601.\n\n"
    "### How to test\n"
    "1. Click **Authorize** and paste a Bearer **access token** from the auth service "
    "(`POST /api/v1/auth/login/request` → `/login/verify`, or `/signup/verify`).\n"
    "2. **Admin-only** endpoints (`platform-kpis`, `payment-mix`, `exports/*`) require an "
    "`admin`/`platform_staff` token; user endpoints (`shop-kpis`, `orders-by-period`, "
    "`payouts-history`) accept any authenticated user.\n"
    "3. `from`/`to` are inclusive ISO-8601 dates; the window is capped at "
    f"`KPI_MAX_RANGE_DAYS` ({settings.kpi_max_range_days} days)."
)

_TAGS_METADATA = [
    {"name": "reporting",
     "description": "KPIs, time series and regulatory (NBR VAT / BTRC DBID) exports. "
                    "Money is integer paisa; date windows use inclusive `from`/`to`."},
    {"name": "ops",
     "description": "Operational contract endpoints — `/ready`, `/health`, `/data`, "
                    "`/metrics`. Public, no auth."},
]


def create_app() -> FastAPI:
    app = FastAPI(title="DOKANDAR Reporting Service", version=settings.code_version,
                  description=_API_DESCRIPTION,
                  contact={"name": "DOKANDAR Platform", "url": "https://dokandar.com.bd",
                           "email": "api@dokandar.com.bd"},
                  license_info={"name": "Proprietary"},
                  servers=[{"url": "https://api.dokandar.com.bd", "description": "prod"},
                           {"url": "http://localhost:10011", "description": "local"}],
                  openapi_tags=_TAGS_METADATA,
                  docs_url=None, redoc_url=None, openapi_url="/openapi.json",
                  swagger_ui_parameters={"persistAuthorization": True},
                  default_response_class=PrettyJSONResponse, lifespan=lifespan)

    @app.get("/docs", include_in_schema=False)
    async def custom_swagger_ui():  # noqa: ANN202
        return get_swagger_ui_html(
            openapi_url=app.openapi_url,
            title="11-reporting API",
            swagger_ui_parameters={"persistAuthorization": True},
        )

    @app.middleware("http")
    async def rid(req, cn):
        r = req.headers.get("x-request-id") or uuid.uuid4().hex
        req.state.request_id = r
        resp = await cn(req); resp.headers["x-request-id"] = r; return resp

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

    app.include_router(ops_router); app.include_router(reporting_router)

    Instrumentator(should_group_status_codes=True, should_ignore_untemplated=True,
                   excluded_handlers=["/metrics","/ready","/health"]).instrument(app).expose(
        app, include_in_schema=False, endpoint="/metrics_promfast")

    def _o():
        if app.openapi_schema: return app.openapi_schema
        s = get_openapi(title=app.title, version=app.version, routes=app.routes,
                        description=app.description, contact=app.contact,
                        license_info=app.license_info, servers=app.servers,
                        tags=app.openapi_tags)
        comps = s.setdefault("components", {})
        schemes = comps.setdefault("securitySchemes", {})
        # Canonical fleet scheme name is `bearerJwt`. FastAPI's HTTPBearer dependency
        # auto-registers the scheme under the key `HTTPBearer` and references it on each
        # authed operation; rename both the scheme and every operation reference so the
        # served spec uses `bearerJwt` (doc-only — same RS256 bearer auth).
        schemes["bearerJwt"] = {"type": "http", "scheme": "bearer", "bearerFormat": "JWT"}
        schemes.pop("HTTPBearer", None)
        for _path, _ops in s.get("paths", {}).items():
            for _method, _op in _ops.items():
                if not isinstance(_op, dict):
                    continue
                sec = _op.get("security")
                if not isinstance(sec, list):
                    continue
                for _req in sec:
                    if isinstance(_req, dict) and "HTTPBearer" in _req:
                        _req["bearerJwt"] = _req.pop("HTTPBearer")
        app.openapi_schema = s
        return s

    app.openapi = _o
    apm_mod.install(app)
    return app


app = create_app()
