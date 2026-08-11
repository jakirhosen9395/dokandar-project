"""FastAPI app factory: lifespan + middleware + routers."""
from __future__ import annotations
import asyncio
import json
import logging
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Any
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from fastapi.exceptions import RequestValidationError
from prometheus_fastapi_instrumentator import Instrumentator
from sqlalchemy import select
from app.api.v1 import auth as v1_auth
from app.config import settings
from app.db.models import Outbox, User
from app.db.session import SessionLocal
from app.grpc import server as grpc_server
from app.messaging import kafka as kafka_mod, rabbitmq as rmq
from app.observability import apm as apm_mod
from app.observability import logging as obs_logging
from app.ops.routes import router as ops_router


class PrettyJSONResponse(JSONResponse):
    """Default response class — every JSON body is rendered indented (2 spaces)
    with a trailing newline, so curl/browsers/jq output is always human-readable.
    Affects /ready, /health, /data, every /api/v1/auth/* response, and every
    error envelope. Does NOT affect /metrics (Prometheus text) or /docs (HTML)."""

    media_type = "application/json"

    def render(self, content: Any) -> bytes:
        return (json.dumps(
            content,
            indent=2,
            ensure_ascii=False,
            sort_keys=False,
            separators=(",", ": "),
        ) + "\n").encode("utf-8")

log = logging.getLogger("auth.main")
_outbox_task: asyncio.Task | None = None
_grpc_task: asyncio.Task | None = None


async def _seed_default_admin() -> None:
    async with SessionLocal() as db:
        existing = (await db.execute(
            select(User).where(User.phone == settings.default_admin_phone)
        )).scalar_one_or_none()
        if existing:
            return
        # Spec §5.3: the default admin lands kyc='verified' (they don't go
        # through the shopkeeper KYC flow). The 0002 migration tries the
        # same UPDATE but runs BEFORE this seed, so we explicitly set it
        # here too.
        u = User(
            phone=settings.default_admin_phone,
            name=settings.default_admin_name,
            role="admin",
            status="active",
            kyc="verified",
            lang="bn",
        )
        db.add(u)
        await db.flush()
        db.add(Outbox(
            topic=settings.kafka_topic_user,
            key=str(u.id),
            payload={
                "event": "UserCreated",
                "user_id": str(u.id), "phone": u.phone, "role": u.role,
                "name": u.name,
                "created_at": datetime.now(timezone.utc).isoformat(),
            },
        ))
        await db.commit()
        log.warning("[seed] default admin created: phone=%s role=admin", u.phone)


@asynccontextmanager
async def lifespan(app: FastAPI):
    obs_logging.configure()
    log.info("auth %s starting up (env=%s tenant=%s)",
             settings.code_version, settings.app_env, settings.tenant)
    await obs_logging.start_mongo_sink()
    await obs_logging.start_es_sink()
    try:
        await rmq.connect()
    except Exception as e:
        log.warning("rabbitmq connect at startup failed (will retry on use): %s", e)
    await _seed_default_admin()
    global _outbox_task, _grpc_task
    _outbox_task = asyncio.create_task(
        kafka_mod.outbox_relay_loop(interval_seconds=2.0),
        name="outbox-relay",
    )
    if settings.grpc_enabled:
        _grpc_task = asyncio.create_task(grpc_server.serve(), name="grpc-server")
    yield
    log.info("auth shutting down")
    if _grpc_task:
        await grpc_server.stop()
        try:
            await _grpc_task
        except Exception:
            pass
    if _outbox_task:
        _outbox_task.cancel()
        try:
            await _outbox_task
        except Exception:
            pass
    await rmq.close()
    await obs_logging.stop_es_sink()
    await obs_logging.stop_mongo_sink()


def create_app() -> FastAPI:
    # Render the runtime identity as a single inline line. Swagger UI
    # places `info.description` immediately below the title block — same
    # visual area as the title/version/spec-version row, but on the next
    # line. (Putting it literally INSIDE the title row would require
    # overriding the Swagger UI HTML chain; not worth it for a label.)
    _identity_md = (
        f"**service_name**: `{settings.service_name}` &nbsp;|&nbsp; "
        f"**code_version**: `{settings.code_version}` &nbsp;|&nbsp; "
        f"**env_version**: `{settings.env_version}` &nbsp;|&nbsp; "
        f"**tenant**: `{settings.tenant}` &nbsp;|&nbsp; "
        f"**env**: `{settings.app_env}`\n\n"
        "### How to test\n"
        "1. **Sign up**: `POST /api/v1/auth/signup/request` with a phone, then "
        "`POST /api/v1/auth/signup/verify` (role `customer`) — returns an "
        "`access_token` + `refresh_token`. With `OTP_ENABLED=true`, recover the "
        "6-digit `code` from the `00-support` OTP viewer; otherwise `code` is optional.\n"
        "2. Click **Authorize** and paste the `access_token` as the Bearer token. "
        "Authenticated routes (`/me`, `/users`, `/kyc/*`) then light up.\n"
        "3. **Login** (existing phone): `POST /login/request` → `/login/verify`. "
        "**Refresh**: `POST /refresh` (single-use; replay revokes the whole family).\n"
        "4. Public reads need no token: `GET /jwks` (verify JWTs offline) and the "
        "`/ready /health /data /metrics` ops surface.\n"
        "5. Roles: self-signup is `customer` only; admin/shopkeeper provision others "
        "via `POST /users`; KYC submit is shopkeeper-only; the KYC queue is "
        "admin/platform_staff."
    )
    app = FastAPI(
        title="DOKANDAR Auth Service",
        version=settings.code_version,
        description=_identity_md,
        contact={
            "name": "DOKANDAR Platform",
            "url": "https://dokandar.com.bd",
            "email": "api@dokandar.com.bd",
        },
        license_info={"name": "Proprietary"},
        servers=[
            {"url": "https://api.dokandar.com.bd", "description": "prod"},
            {"url": "http://localhost:10001", "description": "local"},
        ],
        openapi_tags=[
            {"name": "auth", "description": "Identity: OTP signup/login, token rotation, JWKS, current user."},
            {"name": "kyc", "description": "Shopkeeper KYC submission, status, and admin review queue/decisions."},
            {"name": "admin", "description": "RBAC user provisioning (per the role matrix)."},
            {"name": "ops", "description": "Operational / contract surface: /ready /health /data /metrics."},
        ],
        lifespan=lifespan,
        # docs_url=None: the built-in Swagger route is replaced by a custom
        # /docs below so the browser <title> is exactly "01-auth API" while
        # info.title stays the descriptive "DOKANDAR Auth Service".
        docs_url=None,
        openapi_url="/openapi.json",
        default_response_class=PrettyJSONResponse,
    )

    # Custom Swagger UI: identical to FastAPI's default page, but with the
    # platform-standard browser <title> and persisted Authorize state.
    from fastapi.openapi.docs import get_swagger_ui_html

    @app.get("/docs", include_in_schema=False)
    async def custom_swagger_ui():
        return get_swagger_ui_html(
            openapi_url=app.openapi_url,
            title="01-auth API",
            swagger_ui_parameters={"persistAuthorization": True},
        )

    # Request-id middleware (also feeds the trace_id into structured logs).
    # NOTE: APM middleware install happens LAST (after Instrumentator below) so
    # ElasticAPM ends up as the outermost user-middleware — this is required
    # by the elastic-apm-python docs for transaction contextvars to propagate
    # to Starlette's built-in ServerErrorMiddleware, which is what actually
    # calls end_transaction(). With APM as an inner middleware, spans ship
    # but transactions never get finalized (Kibana Overview / Transactions /
    # Errors / Latency / Throughput stay empty even though Dependencies /
    # Service map / Metrics work because they're derived from spans).
    @app.middleware("http")
    async def request_id(request: Request, call_next):
        rid = request.headers.get("x-request-id") or uuid.uuid4().hex
        request.state.request_id = rid
        response = await call_next(request)
        response.headers["x-request-id"] = rid
        return response

    @app.exception_handler(RequestValidationError)
    async def _validation_exception(request: Request, exc: RequestValidationError):
        return PrettyJSONResponse(
            status_code=422,
            content={"error": {
                "code": "validation_error",
                "message": "Request body failed validation.",
                "request_id": getattr(request.state, "request_id", None),
                "details": [{"field": ".".join(str(p) for p in e["loc"]), "issue": e["msg"]} for e in exc.errors()],
            }},
        )

    # Render HTTPException bodies through PrettyJSONResponse so error envelopes
    # (signup→409, refresh→401, /users→403, etc.) are pretty-printed too.
    from fastapi.exceptions import HTTPException as _HE
    from starlette.exceptions import HTTPException as _SHE

    # Map raw status codes → stable machine-readable error codes for the
    # platform's error envelope. Used when an HTTPException is raised
    # without a structured `detail` (the typical case for framework-level
    # 404 / 405 / 422 / 500). Business-logic raises that supply their own
    # `{"error": {...}}` detail are passed through unchanged.
    _STATUS_TO_CODE = {
        400: "bad_request",
        401: "unauthorized",
        403: "forbidden",
        404: "not_found",
        405: "method_not_allowed",
        409: "conflict",
        413: "payload_too_large",
        415: "unsupported_media_type",
        422: "validation_error",
        429: "rate_limited",
        500: "internal_error",
        502: "bad_gateway",
        503: "service_unavailable",
        504: "gateway_timeout",
    }

    @app.exception_handler(_HE)
    @app.exception_handler(_SHE)
    async def _http_exc(request: Request, exc):
        # Information-hiding hardening: ANY request to an unmapped path returns
        # a bare 404 with no body. The standard contract exposes only
        # /ready /health /data /metrics /docs /openapi.json /api/v1/auth/*;
        # everything else should give back nothing that maps our surface.
        # We deliberately keep 405 / 422 / 500 envelopes so a typo against a
        # known path (e.g. GET on a POST-only endpoint) is still debuggable.
        # Business handlers that raise 404 with a structured `detail` dict are
        # passed through unchanged.
        if exc.status_code == 404 and not isinstance(exc.detail, dict):
            # Bound APM transaction cardinality: name unmatched 404s by method (a single
            # "<METHOD> unmatched") instead of the raw scanned path, so a scanner/typo path
            # never spawns a new transaction name (no raw URLs, no cardinality explosion).
            try:
                import elasticapm
                elasticapm.set_transaction_name(f"{request.method} unmatched", override=True)
            except Exception:
                pass
            return Response(status_code=404)
        rid = getattr(request.state, "request_id", None)
        if isinstance(exc.detail, dict):
            body = exc.detail
        else:
            code = _STATUS_TO_CODE.get(exc.status_code, "http_error")
            body = {"error": {
                "code": code,
                "message": str(exc.detail or "").strip() or code.replace("_", " ").title(),
                "request_id": rid,
            }}
        # tag request_id if the inner handler didn't
        if isinstance(body, dict) and "error" in body and not body["error"].get("request_id"):
            body["error"]["request_id"] = rid
        return PrettyJSONResponse(status_code=exc.status_code, content=body)

    # Dependency-unavailable handler. When Redis/Postgres go unreachable
    # mid-request, the underlying drivers raise their own connection errors
    # (redis.exceptions.ConnectionError / TimeoutError, asyncpg connection
    # errors, sqlalchemy.exc.OperationalError / InterfaceError). Without
    # this catcher Starlette would emit a bare 500 + non-JSON body. The
    # spec (§7) mandates `503 dependency_unavailable` for these cases.
    # /ready already gates the LB on postgres + redis — this handler only
    # protects clients that bypass the gate (kubectl port-forward, internal
    # probes, in-flight requests during a graceful drain).
    import redis.exceptions as _redis_exc
    import sqlalchemy.exc as _sa_exc
    import asyncpg.exceptions as _pg_exc

    async def _dependency_unavailable(request: Request, exc):
        rid = getattr(request.state, "request_id", None)
        log.warning("dependency_unavailable on %s %s — %s: %s",
                    request.method, request.url.path, type(exc).__name__, str(exc)[:120])
        # Surface the dependency failure in the APM Errors tab (it's handled as a 503 here,
        # so the agent would not otherwise capture it as an error event).
        try:
            import elasticapm
            elasticapm.capture_exception()
        except Exception:
            pass
        return PrettyJSONResponse(
            status_code=503,
            content={"error": {
                "code": "dependency_unavailable",
                "message": "A required dependency is down. Please retry shortly.",
                "request_id": rid,
            }},
        )

    # FastAPI's decorator form only accepts a single class — register each
    # type individually via add_exception_handler. Subclasses of each
    # registered class are caught (so OperationalError covers most asyncpg
    # connection errors via SQLAlchemy's wrapping).
    for _cls in (
        _redis_exc.ConnectionError,
        _redis_exc.TimeoutError,
        _redis_exc.BusyLoadingError,
        _sa_exc.OperationalError,
        _sa_exc.InterfaceError,
        _sa_exc.DBAPIError,
        _pg_exc.ConnectionDoesNotExistError,
        _pg_exc.CannotConnectNowError,
        _pg_exc.ConnectionFailureError,
        ConnectionRefusedError,
        ConnectionResetError,
    ):
        app.add_exception_handler(_cls, _dependency_unavailable)

    # Routers
    app.include_router(ops_router)
    app.include_router(v1_auth.router)

    # Prometheus /metrics — RED metrics from instrumentator + auth-specific
    # counters/gauges registered in app.observability.metrics. The
    # before-scrape hook refreshes the on-DB gauges (auth_active_refresh_tokens,
    # auth_outbox_pending) so dashboards never read stale numbers.
    from app.observability import metrics as M  # noqa: F401 — imports register collectors
    @app.middleware("http")
    async def _refresh_gauges_on_metrics_scrape(request: Request, call_next):
        if request.url.path == "/metrics":
            try:
                await M.refresh_gauges_from_db()
            except Exception:
                pass
        return await call_next(request)
    Instrumentator(excluded_handlers=["/health", "/ready", "/data"]).instrument(app).expose(app, endpoint="/metrics")

    # APM middleware MUST be installed last so it's the outermost user-middleware
    # (see the note above the request_id middleware).
    apm_mod.install(app)

    return app


app = create_app()
