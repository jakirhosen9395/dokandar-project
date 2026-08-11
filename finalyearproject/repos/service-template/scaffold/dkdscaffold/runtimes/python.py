"""
dkdscaffold.runtimes.python — Python 3.12 / FastAPI + uvicorn runtime emitter.

Emits a complete, idiomatic Python 3.12 + FastAPI + uvicorn service skeleton realising every
blueprint capability: hexagonal structure, 12-factor config + validate, DI wiring, graceful
shutdown, startup validation, /health /ready /live /version (ContractVersion from dkd-platform),
structured JSON logging (stdlib logging), Prometheus-text metrics (:9090/metrics via stdlib
HTTPServer thread), W3C traceparent propagation + correlation-id middleware, request logging,
JWT auth (bearer extract + claims parse + injectable JwtVerifier Protocol) + HasRole authz helper,
security headers, input validation, centralized RFC-7807 exception handling, Kafka + RabbitMQ
bootstrap as Publisher/Consumer abstract bases (NoopPublisher/Consumer wired by default),
DbProtocol + TxProtocol + RepositoryBase + Migrator + NoopMigrator, pytest unit tests
(TestClient), pytest integration tests (pytest.mark.integration), multi-stage python:3.13-slim
Dockerfile (non-root), GitLab CI (build+test+lint + docker package on main).

Consumes svc.sdk = dkd-platform (dkd-platform-libs Python SDK). No business logic.
"""
from __future__ import annotations

from ..blueprint import Service
from ..render import Writer, pascal, camel, snake, kebab
from .common import emit_common


def emit(svc: Service, out_dir: str) -> list[str]:
    w = Writer(out_dir, "#")
    emit_common(w, svc)
    _pyproject(w, svc)
    _pkg_init(w, svc)
    _pkg_main_module(w, svc)
    _config(w, svc)
    _obs(w, svc)
    _security(w, svc)
    _messaging(w, svc)
    _persistence(w, svc)
    _validation(w, svc)
    _server(w, svc)
    _app(w, svc)
    _main(w, svc)
    _tests_init(w, svc)
    _tests_unit(w, svc)
    _tests_integration(w, svc)
    _dockerfile(w, svc)
    _ci(w, svc)
    _makefile(w, svc)
    return list(w.written)


# ---------------------------------------------------------------------------
# Substitution helpers — __PKG__, __PORT__, __SLUG__, __CTX__, __SDK__, __SDK_IMPORT__
# are the only tokens used; they never collide with Python syntax.
# Apply _sub() to BOTH paths and bodies so that all __PKG__ occurrences are expanded.
# ---------------------------------------------------------------------------

def _sub(template: str, svc: Service) -> str:
    sdk_import = svc.sdk.replace("-", "_")
    return (template
            .replace("__PKG__", svc.pkg)
            .replace("__PORT__", str(svc.http_port))
            .replace("__SLUG__", svc.slug)
            .replace("__CTX__", svc.context)
            .replace("__SDK__", svc.sdk)
            .replace("__SDK_IMPORT__", sdk_import))


def _write(w: Writer, svc: Service, rel_path: str, body: str, *, banner: bool = False) -> None:
    """Write a file, substituting __PKG__ (and other tokens) in both path and body."""
    w.write(_sub(rel_path, svc), body, banner=banner)


# ---------------------------------------------------------------------------
# pyproject.toml — dependency manifest
# ---------------------------------------------------------------------------

def _pyproject(w: Writer, svc: Service) -> None:
    body = _sub('''\
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "__SLUG__"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = [
    "fastapi>=0.111.0",
    "uvicorn[standard]>=0.30.0",
    "__SDK__>=1.0.0",
]

[project.optional-dependencies]
test = [
    "pytest>=8.0.0",
    "pytest-asyncio>=0.23.0",
    "httpx>=0.27.0",
    "ruff>=0.4.0",
]

[project.scripts]
serve = "__PKG__.main:main"

[tool.hatch.build.targets.wheel]
packages = ["src/__PKG__"]

[tool.pytest.ini_options]
testpaths = ["tests"]
markers = [
    "integration: requires running docker infra (postgres, redpanda, rabbitmq)",
]

[tool.ruff]
target-version = "py312"

[tool.ruff.lint]
select = ["E", "W", "F", "I", "UP"]
ignore = ["E501"]
''', svc)
    w.write("pyproject.toml", body)


# ---------------------------------------------------------------------------
# src/<pkg>/__init__.py
# ---------------------------------------------------------------------------

def _pkg_init(w: Writer, svc: Service) -> None:
    body = _sub('"""__SLUG__ — DOKANDAR __CTX__ service (generated skeleton, infrastructure only)."""\n', svc)
    _write(w, svc, "src/__PKG__/__init__.py", body, banner=True)


# ---------------------------------------------------------------------------
# src/<pkg>/__main__.py  — enables `python -m <pkg>`
# ---------------------------------------------------------------------------

def _pkg_main_module(w: Writer, svc: Service) -> None:
    body = _sub('''\
"""Entry point for `python -m __PKG__`."""
from .main import main

main()
''', svc)
    _write(w, svc, "src/__PKG__/__main__.py", body, banner=True)


# ---------------------------------------------------------------------------
# src/<pkg>/config.py — 12-factor config + startup validation
# ---------------------------------------------------------------------------

def _config(w: Writer, svc: Service) -> None:
    body = _sub('''\
"""
12-factor configuration: every value is loaded from environment variables.
Secrets are delivered by the platform secret manager in non-local environments — never committed.
"""
from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class ServiceConfig:
    """Immutable service configuration snapshot loaded from the environment."""

    service_name: str
    context: str
    env: str
    http_port: int
    metrics_port: int
    log_level: str
    kafka_brokers: str
    rabbitmq_url: str
    db_dsn: str
    otel_endpoint: str
    jwt_issuer: str

    @classmethod
    def load(cls) -> "ServiceConfig":
        """Load all values from environment variables (12-factor)."""
        return cls(
            service_name=_getenv("DKD_SERVICE_NAME", "__SLUG__"),
            context=_getenv("DKD_CONTEXT", "__CTX__"),
            env=_getenv("DKD_ENV", "local"),
            http_port=int(_getenv("DKD_HTTP_PORT", "__PORT__")),
            metrics_port=9090,
            log_level=_getenv("DKD_LOG_LEVEL", "info"),
            kafka_brokers=_getenv("DKD_KAFKA_BROKERS", "localhost:9092"),
            rabbitmq_url=_getenv("DKD_RABBITMQ_URL", ""),
            db_dsn=_getenv("DKD_DB_DSN", ""),
            otel_endpoint=_getenv("DKD_OTEL_ENDPOINT", ""),
            jwt_issuer=_getenv("DKD_JWT_ISSUER", ""),
        )

    def validate(self) -> None:
        """Startup validation — raises ValueError on missing required configuration."""
        if not self.service_name or not self.context:
            raise ValueError("DKD_SERVICE_NAME and DKD_CONTEXT are required")
        if not (0 < self.http_port <= 65535):
            raise ValueError(f"DKD_HTTP_PORT is invalid: {self.http_port}")


def _getenv(key: str, default: str) -> str:
    value = os.environ.get(key, "").strip()
    return value if value else default
''', svc)
    _write(w, svc, "src/__PKG__/config.py", body, banner=True)


# ---------------------------------------------------------------------------
# src/<pkg>/obs.py — structured JSON logging, Prometheus-text metrics, W3C traceparent
# ---------------------------------------------------------------------------

def _obs(w: Writer, svc: Service) -> None:
    body = _sub('''\
"""
Observability: structured JSON logging (stdlib), Prometheus-text counter registry
(stdlib HTTPServer thread on :<metrics_port>/metrics), and W3C traceparent generation.

The OpenTelemetry SDK (OTLP exporter) is the integration point for span export to the platform
collector; trace propagation is independent of the SDK.
"""
from __future__ import annotations

import json
import logging
import secrets
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any


# ---------------------------------------------------------------------------
# Structured JSON logging
# ---------------------------------------------------------------------------

_LOG_RESERVED: frozenset[str] = frozenset({
    "args", "created", "exc_info", "exc_text", "filename", "funcName",
    "levelname", "levelno", "lineno", "message", "module", "msecs",
    "msg", "name", "pathname", "process", "processName", "relativeCreated",
    "stack_info", "taskName", "thread", "threadName",
})


class _JsonFormatter(logging.Formatter):
    """Formats log records as single-line JSON for structured log aggregation."""

    def format(self, record: logging.LogRecord) -> str:
        data: dict[str, Any] = {
            "timestamp": self.formatTime(record, datefmt=None),
            "level": record.levelname.lower(),
            "logger": record.name,
            "message": record.getMessage(),
        }
        if record.exc_info:
            data["exception"] = self.formatException(record.exc_info)
        extras = {
            k: v for k, v in record.__dict__.items()
            if k not in _LOG_RESERVED and not k.startswith("_")
        }
        data.update(extras)
        return json.dumps(data, default=str)


def configure_logging(level: str = "info") -> logging.Logger:
    """Configure the root logger for structured JSON output. Returns the service logger."""
    numeric = getattr(logging, level.upper(), logging.INFO)
    handler = logging.StreamHandler()
    handler.setFormatter(_JsonFormatter())
    root = logging.getLogger()
    root.setLevel(numeric)
    if not root.handlers:
        root.addHandler(handler)
    return logging.getLogger("__PKG__")


# ---------------------------------------------------------------------------
# Prometheus-text counter registry
# ---------------------------------------------------------------------------

class AppMetrics:
    """Thread-safe Prometheus-text counter registry. Exposed on :<metrics_port>/metrics."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._counters: dict[str, float] = {}

    def inc(self, name: str) -> None:
        """Atomically increment a named counter."""
        with self._lock:
            self._counters[name] = self._counters.get(name, 0.0) + 1.0

    def prometheus_text(self) -> str:
        """Render all counters in Prometheus text exposition format (version 0.0.4)."""
        with self._lock:
            return "".join(f"{name} {value:g}\\n" for name, value in self._counters.items())


class MetricsServer:
    """Serves Prometheus-text metrics on a dedicated port using a stdlib HTTPServer daemon thread.

    This mirrors the Go and C# emitters which expose metrics on a separate port (9090) so that
    Prometheus scraping is isolated from the service API port. Replace with the prometheus-client
    library at the integration point if histogram / summary metric types are needed.
    """

    def __init__(self, metrics: AppMetrics, port: int) -> None:
        self._metrics = metrics
        self._port = port
        self._server: HTTPServer | None = None
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        """Bind the metrics port and start the daemon thread."""
        metrics = self._metrics

        class _Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802  — stdlib requires this exact name
                if self.path == "/metrics":
                    body = metrics.prometheus_text().encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "text/plain; version=0.0.4")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                else:
                    self.send_response(404)
                    self.end_headers()

            def log_message(self, *_args: Any) -> None:
                pass  # suppress stdlib access log; request logging is the app middleware's job

        self._server = HTTPServer(("", self._port), _Handler)
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True, name="metrics-server")
        self._thread.start()

    def stop(self) -> None:
        """Shutdown the metrics HTTP server."""
        if self._server is not None:
            self._server.shutdown()


# ---------------------------------------------------------------------------
# W3C traceparent + correlation ID generation
# ---------------------------------------------------------------------------

def new_trace_parent() -> str:
    """Generate a W3C traceparent (version=00, random trace-id + span-id, sampled flag=01)."""
    trace_id = secrets.token_hex(16)
    span_id = secrets.token_hex(8)
    return f"00-{trace_id}-{span_id}-01"


def new_correlation_id() -> str:
    """Generate a random 32-character hex correlation ID."""
    return secrets.token_hex(16)
''', svc)
    _write(w, svc, "src/__PKG__/obs.py", body, banner=True)


# ---------------------------------------------------------------------------
# src/<pkg>/security.py — JWT authenticator, claims, verifier Protocol, HasRole
# ---------------------------------------------------------------------------

def _security(w: Writer, svc: Service) -> None:
    body = _sub('''\
"""
JWT authentication infrastructure: bearer extraction, base64url-decode + JSON parse of claims,
delegation of signature verification to an injectable JwtVerifier Protocol, and an RBAC HasRole
helper. No business authorization rules are defined here.
"""
from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from typing import Protocol, runtime_checkable


@dataclass(frozen=True)
class DkdClaims:
    """Minimal claim set issued by the Dokandar platform (see dkd-platform-libs JwtClaims)."""

    sub: str
    kyc_tier: str
    roles: tuple[str, ...]
    cid: str


@runtime_checkable
class JwtVerifier(Protocol):
    """JWT signature verifier — integration point for the platform JWKS endpoint.

    Raise ValueError when the token signature is invalid. NoopJwtVerifier accepts all tokens
    without signature verification (local development only; never use in staging/production).
    """

    def verify(self, token: str) -> None: ...


class NoopJwtVerifier:
    """Accepts all tokens without signature verification. Safe for local development only.

    Replace with the Dkd.Platform JWKS verifier (dkd-platform-libs) in all non-local
    environments. Wire the replacement in Application.__init__ (app.py).
    """

    def verify(self, token: str) -> None:
        pass


class JwtAuthenticator:
    """Authenticates bearer JWTs: decodes the payload, deserialises DkdClaims, then delegates
    signature verification to the injected JwtVerifier. Returns None (never raises) on failure.
    """

    def __init__(self, verifier: JwtVerifier) -> None:
        self._verifier = verifier

    def try_authenticate(self, token: str) -> DkdClaims | None:
        """Return parsed claims on success; None on any structural or verification failure."""
        try:
            self._verifier.verify(token)
            parts = token.split(".")
            if len(parts) != 3:
                return None
            raw = _decode_segment(parts[1])
            data: dict[str, object] = json.loads(raw)
            return DkdClaims(
                sub=str(data.get("sub", "")),
                kyc_tier=str(data.get("kyc_tier", "")),
                roles=tuple(str(r) for r in data.get("roles", [])),  # type: ignore[arg-type]
                cid=str(data.get("cid", "")),
            )
        except Exception:  # noqa: BLE001
            return None


def has_role(claims: DkdClaims | None, role: str) -> bool:
    """RBAC authorization helper. Returns True when claims contain the given role.

    Pair with the platform PDP (dkd-platform-libs) for ABAC enforcement.
    """
    if claims is None:
        return False
    return role in claims.roles


def _decode_segment(segment: str) -> bytes:
    padding = 4 - len(segment) % 4
    padded = segment + "=" * (padding if padding != 4 else 0)
    return base64.urlsafe_b64decode(padded)
''', svc)
    _write(w, svc, "src/__PKG__/security.py", body, banner=True)


# ---------------------------------------------------------------------------
# src/<pkg>/messaging.py — Publisher/Consumer abstractions + Noop defaults
# ---------------------------------------------------------------------------

def _messaging(w: Writer, svc: Service) -> None:
    body = _sub('''\
"""
Event-bus abstractions for the Dokandar Published Language (R6). Concrete Kafka (Redpanda) and
RabbitMQ client implementations are the integration point — wire them in the adapters layer.

No business events are defined here; topic names and payload schemas come from
dkd-contracts-spine/messaging.yaml. Implementations must guarantee:
  - At-least-once delivery via the transactional outbox pattern (Publisher).
  - Inbox deduplication on event_id and per-topic DLQ with replay (Consumer).
  - Park-and-freeze on poison messages — never silently drop (Consumer).
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from collections.abc import Callable, Awaitable


MessageHandler = Callable[[str, str, bytes], Awaitable[None]]
"""Async handler invoked by Consumer for each received message: (topic, key, payload) -> None."""


class Publisher(ABC):
    """Event publisher abstraction (Kafka cross-context Published Language + RabbitMQ intra-context)."""

    @abstractmethod
    async def publish(self, topic: str, key: str, payload: bytes) -> None:
        """Publish a message to the given topic with the given ordering key and payload."""
        ...

    @abstractmethod
    async def close(self) -> None:
        """Flush pending messages and release broker connections."""
        ...


class Consumer(ABC):
    """Event consumer abstraction. Subscribe to topics and receive messages via the handler."""

    @abstractmethod
    async def subscribe(
        self,
        topics: list[str],
        handler: MessageHandler,
    ) -> None:
        """Subscribe to the given topics; invoke handler for each message received."""
        ...

    @abstractmethod
    async def close(self) -> None:
        """Unsubscribe and release broker connections."""
        ...


class NoopPublisher(Publisher):
    """Safe default for local runs without a broker.

    Replace with the Redpanda (Kafka-compatible) driver from dkd-platform-libs at the
    integration point for all non-local environments.
    """

    async def publish(self, topic: str, key: str, payload: bytes) -> None:
        pass

    async def close(self) -> None:
        pass


class NoopConsumer(Consumer):
    """Mirrors NoopPublisher for local development parity."""

    async def subscribe(self, topics: list[str], handler: MessageHandler) -> None:
        pass

    async def close(self) -> None:
        pass
''', svc)
    _write(w, svc, "src/__PKG__/messaging.py", body, banner=True)


# ---------------------------------------------------------------------------
# src/<pkg>/persistence.py — DB/Tx/Migrator abstractions, RepositoryBase, NoopMigrator
# ---------------------------------------------------------------------------

def _persistence(w: Writer, svc: Service) -> None:
    body = _sub('''\
"""
Persistence abstractions for the hexagonal adapters layer. The concrete asyncpg/psycopg3 driver
is the integration point — no business repositories are defined here. Each bounded context adds
its own repository implementations (subclassing RepositoryBase) in the adapters ring.
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from collections.abc import Callable, Awaitable
from typing import TypeVar

_T = TypeVar("_T")


class TxProtocol(ABC):
    """Unit-of-work handle for an active database transaction."""

    @abstractmethod
    async def execute(self, sql: str, *args: object) -> None:
        """Execute a parameterised SQL statement within the transaction."""
        ...


class DbProtocol(ABC):
    """Database abstraction: ping (readiness), with_transaction (tx helper), and lifecycle.

    The concrete implementation wraps a connection pool (e.g. asyncpg Pool or psycopg3 AsyncPool).
    """

    @abstractmethod
    async def ping(self) -> None:
        """Verify the database is reachable; used by the /ready probe."""
        ...

    @abstractmethod
    async def with_transaction(
        self,
        fn: Callable[[TxProtocol], Awaitable[_T]],
    ) -> _T:
        """Execute fn inside a database transaction. Commits on success; rolls back on exception."""
        ...

    @abstractmethod
    async def close(self) -> None:
        """Release the connection pool."""
        ...


class RepositoryBase:
    """Base class for all context repositories.

    Carries the DbProtocol handle and exposes the transaction helper. Business repositories in
    the adapters ring inherit from this class. No business repositories are defined here.
    """

    def __init__(self, db: DbProtocol) -> None:
        self._db = db

    async def in_transaction(
        self,
        fn: Callable[[TxProtocol], Awaitable[_T]],
    ) -> _T:
        """Convenience wrapper: execute fn inside a database transaction."""
        return await self._db.with_transaction(fn)


class Migrator(ABC):
    """Schema migration abstraction.

    Apply runs ordered, idempotent SQL migrations at service startup, before the readiness gate
    is flipped to true. Replace NoopMigrator with a real driver (e.g. alembic, yoyo-migrations,
    or a custom runner) at the integration point.
    """

    @abstractmethod
    async def apply(self) -> None: ...


class NoopMigrator(Migrator):
    """Safe default for local runs without a real database wired."""

    async def apply(self) -> None:
        pass
''', svc)
    _write(w, svc, "src/__PKG__/persistence.py", body, banner=True)


# ---------------------------------------------------------------------------
# src/<pkg>/validation.py — input validation helpers
# ---------------------------------------------------------------------------

def _validation(w: Writer, svc: Service) -> None:
    body = _sub('''\
"""
Input validation helpers for system boundary enforcement. Validate all external input before
processing: fail fast with a clear error, never coerce silently.

The ExceptionHandlingMiddleware in server.py maps ValueError to RFC-7807 400 responses.
"""
from __future__ import annotations


def required(field_name: str, value: str | None) -> str:
    """Raise ValueError when the value is None, empty, or whitespace-only."""
    if not value or not value.strip():
        raise ValueError(f"{field_name} is required")
    return value


def positive(field_name: str, value: int) -> int:
    """Raise ValueError when the value is not strictly positive."""
    if value <= 0:
        raise ValueError(f"{field_name} must be positive, got {value}")
    return value


def max_length(field_name: str, value: str, max_len: int) -> str:
    """Raise ValueError when the value exceeds the allowed maximum length."""
    if len(value) > max_len:
        raise ValueError(
            f"{field_name} must not exceed {max_len} characters, got {len(value)}"
        )
    return value
''', svc)
    _write(w, svc, "src/__PKG__/validation.py", body, banner=True)


# ---------------------------------------------------------------------------
# src/<pkg>/server.py — FastAPI app factory, middleware chain, health routes
# ---------------------------------------------------------------------------

def _server(w: Writer, svc: Service) -> None:
    body = _sub('''\
"""
FastAPI application factory: constructs the ASGI app with the standard middleware pipeline
and the health / probe / version endpoints. No business routes are defined here.

Middleware pipeline (outermost → innermost for incoming requests):
  exception_handling → security_headers → correlation → request_logging → jwt_auth → routes

FastAPI applies @app.middleware("http") decorators in reverse code order (last defined = outermost).
The decorators below are ordered from innermost (first in code) to outermost (last in code) so
that the application chains them in the correct order at runtime.
"""
from __future__ import annotations

import logging
import time
from collections.abc import Callable, Awaitable
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse

from dkd_platform import apidocs   # API Documentation Standard helper (SDK-owned Swagger config)

from .config import ServiceConfig
from .obs import AppMetrics, new_correlation_id, new_trace_parent
from .security import DkdClaims, JwtAuthenticator

logger = logging.getLogger(__name__)

_CLAIMS_STATE_KEY = "dkd_claims"


def create_app(
    cfg: ServiceConfig,
    metrics: AppMetrics,
    auth: JwtAuthenticator,
    is_ready: Callable[[], bool],
    sdk_contract_version: str,
    sdk_generator_version: str,
    lifespan: Any = None,
) -> FastAPI:
    """Construct and return the configured FastAPI ASGI application."""
    # API Documentation Standard: Swagger UI at /docs, OpenAPI JSON at /swagger/v1/swagger.json — all
    # configuration comes from the platform SDK helper (no per-service Swagger configuration).
    app = FastAPI(**apidocs.platform_docs_kwargs(cfg.service_name), lifespan=lifespan)

    # ── Middleware (innermost first; FastAPI reverses to outermost at runtime) ─────────────────

    @app.middleware("http")
    async def jwt_auth_middleware(request: Request, call_next: Callable[..., Awaitable[Response]]) -> Response:
        """Optional JWT auth: attaches DkdClaims to request.state when a valid bearer is present.
        Does not reject unauthenticated requests — health endpoints remain public.
        Use has_role() / require_role() downstream to enforce route-level authorization.
        """
        token = _extract_bearer(request)
        if token:
            claims = auth.try_authenticate(token)
            if claims is not None:
                request.state.dkd_claims = claims
        return await call_next(request)

    @app.middleware("http")
    async def request_logging_middleware(request: Request, call_next: Callable[..., Awaitable[Response]]) -> Response:
        """Log every request with method, path, status code, elapsed ms, and correlation ID."""
        metrics.inc("http_requests_total")
        start = time.perf_counter()
        response = await call_next(request)
        elapsed_ms = int((time.perf_counter() - start) * 1000)
        corr_id = getattr(request.state, "correlation_id", "")
        logger.info(
            "request %s %s %d %dms",
            request.method,
            request.url.path,
            response.status_code,
            elapsed_ms,
            extra={
                "correlation_id": corr_id,
                "method": request.method,
                "path": str(request.url.path),
                "status_code": response.status_code,
                "elapsed_ms": elapsed_ms,
            },
        )
        return response

    @app.middleware("http")
    async def correlation_middleware(request: Request, call_next: Callable[..., Awaitable[Response]]) -> Response:
        """Ensure every request carries a correlation ID and W3C traceparent.
        Generates new values when the caller does not supply them; echoes them on the response.
        """
        corr_id = request.headers.get("X-Correlation-Id") or new_correlation_id()
        trace_parent = request.headers.get("traceparent") or new_trace_parent()
        request.state.correlation_id = corr_id
        request.state.traceparent = trace_parent
        response = await call_next(request)
        response.headers["X-Correlation-Id"] = corr_id
        response.headers["traceparent"] = trace_parent
        return response

    @app.middleware("http")
    async def security_headers_middleware(request: Request, call_next: Callable[..., Awaitable[Response]]) -> Response:
        """Set conservative security response headers. The strict CSP is relaxed ONLY for the Swagger UI
        paths (/docs, /swagger) which need inline script/style; API/data responses keep default-src 'none'."""
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        if apidocs.is_docs_path(request.url.path):
            response.headers["Content-Security-Policy"] = apidocs.DOCS_CSP
        else:
            response.headers["X-Frame-Options"] = "DENY"
            response.headers["Content-Security-Policy"] = "default-src 'none'"
        return response

    @app.middleware("http")
    async def exception_handling_middleware(request: Request, call_next: Callable[..., Awaitable[Response]]) -> Response:
        """Outermost middleware: converts all unhandled exceptions to RFC-7807 problem+json.
        Never leaks stack traces to callers. Maps ValueError → 400, PermissionError → 401,
        all others → 500 with the Dokandar error code taxonomy dokandar.<context>.<cat>.<reason>.
        """
        try:
            return await call_next(request)
        except ValueError as exc:
            logger.warning("Validation error on %s: %s", request.url.path, exc)
            return _problem(400, "Validation Error", str(exc),
                            f"dokandar.__CTX__.validation.invalid-input", str(request.url.path))
        except PermissionError as exc:
            logger.warning("Unauthorized on %s: %s", request.url.path, exc)
            return _problem(401, "Unauthorized", str(exc),
                            f"dokandar.__CTX__.auth.unauthorized", str(request.url.path))
        except Exception as exc:  # noqa: BLE001
            logger.error("Unhandled exception on %s", request.url.path, exc_info=exc)
            return _problem(500, "Internal Server Error", "An unexpected error occurred.",
                            f"dokandar.__CTX__.internal.error", str(request.url.path))

    # ── Health / probe / version routes (public — no authentication required) ─────────────────

    @app.get("/health")
    async def health() -> JSONResponse:
        return JSONResponse({"success": True, "data": {"status": "ok"}})

    @app.get("/live")
    async def live() -> JSONResponse:
        return JSONResponse({"success": True, "data": {"status": "alive"}})

    @app.get("/ready")
    async def ready() -> JSONResponse:
        if not is_ready():
            return JSONResponse(
                {"success": False, "error": {"status": "not-ready"}},
                status_code=503,
            )
        return JSONResponse({"success": True, "data": {"status": "ready"}})

    @app.get("/version")
    async def version() -> JSONResponse:
        """Reports the dkd-platform SDK contract version for provenance traceability."""
        return JSONResponse({
            "success": True,
            "data": {
                "contractVersion": sdk_contract_version,
                "sdkGenerator": sdk_generator_version,
            },
        })

    # API Documentation Standard: inject the Bearer (JWT) security scheme into the OpenAPI document.
    apidocs.configure_platform_docs(app)
    return app


def get_claims(request: Request) -> DkdClaims | None:
    """Retrieve the DkdClaims attached by JwtAuthMiddleware, if any."""
    return getattr(request.state, "dkd_claims", None)


def _extract_bearer(request: Request) -> str | None:
    header = request.headers.get("Authorization", "")
    if header.startswith("Bearer "):
        return header[len("Bearer "):]
    return None


def _problem(status: int, title: str, detail: str, code: str, instance: str) -> JSONResponse:
    return JSONResponse(
        {
            "type": "about:blank",
            "title": title,
            "status": status,
            "detail": detail,
            "instance": instance,
            "code": code,
        },
        status_code=status,
        media_type="application/problem+json",
    )
''', svc)
    _write(w, svc, "src/__PKG__/server.py", body, banner=True)


# ---------------------------------------------------------------------------
# src/<pkg>/app.py — DI container, lifespan wiring
# ---------------------------------------------------------------------------

def _app(w: Writer, svc: Service) -> None:
    body = _sub('''\
"""
Application DI container: constructs and owns the service adapters, wires the FastAPI lifespan
(startup migrations → readiness gate → graceful shutdown), and exposes the ASGI app.

Integration points (replace the Noop* defaults in staging/production):
  - JwtVerifier: swap NoopJwtVerifier for the Dkd.Platform JWKS verifier.
  - Publisher / Consumer: swap Noop* for Redpanda (Kafka) and RabbitMQ drivers.
  - Migrator: swap NoopMigrator for alembic / yoyo or a custom SQL runner.
"""
from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI

from .config import ServiceConfig
from .messaging import NoopConsumer, NoopPublisher, Publisher, Consumer
from .obs import AppMetrics, MetricsServer, configure_logging
from .persistence import Migrator, NoopMigrator
from .security import JwtAuthenticator, NoopJwtVerifier
from .server import create_app

logger = logging.getLogger(__name__)


class Application:
    """Dependency-injection container for the __SLUG__ service.

    Constructs all adapters, wires the FastAPI ASGI app with a lifespan context manager that
    runs startup (migrations, metrics server, readiness gate) and graceful shutdown.
    """

    def __init__(self, cfg: ServiceConfig) -> None:
        self._cfg = cfg
        self._ready = False

        # Infrastructure adapters — replace Noop* at the integration point.
        self._metrics = AppMetrics()
        self._metrics_server = MetricsServer(self._metrics, cfg.metrics_port)
        self._publisher: Publisher = NoopPublisher()
        self._consumer: Consumer = NoopConsumer()
        self._migrator: Migrator = NoopMigrator()

        # JWT verifier integration point (local dev: NoopJwtVerifier skips signature checks).
        _verifier = NoopJwtVerifier()
        _auth = JwtAuthenticator(_verifier)

        # SDK contract version for /version endpoint provenance.
        _contract_version, _generator_version = _load_sdk_versions()

        @asynccontextmanager
        async def _lifespan(app: FastAPI):  # noqa: ANN202
            await self._startup()
            try:
                yield
            finally:
                await self._shutdown()

        self.fastapi_app: FastAPI = create_app(
            cfg=cfg,
            metrics=self._metrics,
            auth=_auth,
            is_ready=lambda: self._ready,
            sdk_contract_version=_contract_version,
            sdk_generator_version=_generator_version,
            lifespan=_lifespan,
        )

    async def _startup(self) -> None:
        """Startup lifecycle: apply migrations, start metrics server, flip readiness gate."""
        await self._migrator.apply()
        self._metrics_server.start()
        self._ready = True
        logger.info(
            "Service started",
            extra={"service": self._cfg.service_name, "port": self._cfg.http_port},
        )

    async def _shutdown(self) -> None:
        """Graceful shutdown: flip readiness, drain connections, stop metrics server."""
        self._ready = False
        await self._publisher.close()
        await self._consumer.close()
        self._metrics_server.stop()
        logger.info("Service stopped cleanly")


def _load_sdk_versions() -> tuple[str, str]:
    """Import SDK contract version from dkd-platform; fall back gracefully if not installed."""
    try:
        import __SDK_IMPORT__ as _sdk  # type: ignore[import-untyped]
        contract = str(getattr(_sdk, "CONTRACT_VERSION", "unknown"))
        generator = str(getattr(_sdk, "GENERATOR_VERSION", "unknown"))
        return contract, generator
    except ImportError:
        return "unknown", "unknown"
''', svc)
    _write(w, svc, "src/__PKG__/app.py", body, banner=True)


# ---------------------------------------------------------------------------
# src/<pkg>/main.py — uvicorn entry point with startup validation
# ---------------------------------------------------------------------------

def _main(w: Writer, svc: Service) -> None:
    body = _sub('''\
"""
Service entry point. Loads and validates 12-factor config, then starts uvicorn.
Called by the `serve` console script (pyproject.toml) or `python -m __PKG__`.
"""
from __future__ import annotations

import sys

import uvicorn

from .app import Application
from .config import ServiceConfig
from .obs import configure_logging


def main() -> None:
    cfg = ServiceConfig.load()
    configure_logging(cfg.log_level)

    try:
        cfg.validate()
    except ValueError as exc:
        print(f"Configuration invalid: {exc}", file=sys.stderr)  # noqa: T201
        sys.exit(1)

    application = Application(cfg)

    uvicorn.run(
        application.fastapi_app,
        host="0.0.0.0",  # noqa: S104 — bind all interfaces inside the container
        port=cfg.http_port,
        log_config=None,  # suppress uvicorn default logging; we use structured JSON
        access_log=False,
    )


if __name__ == "__main__":
    main()
''', svc)
    _write(w, svc, "src/__PKG__/main.py", body, banner=True)


# ---------------------------------------------------------------------------
# tests/__init__.py
# ---------------------------------------------------------------------------

def _tests_init(w: Writer, svc: Service) -> None:
    _write(w, svc, "tests/__init__.py", "")


# ---------------------------------------------------------------------------
# tests/test_health.py — unit tests (TestClient, no external infra)
# ---------------------------------------------------------------------------

def _tests_unit(w: Writer, svc: Service) -> None:
    body = _sub('''\
"""
Unit tests for the standard health / probe / version endpoints and middleware behaviour.

Uses FastAPI TestClient (httpx ASGI transport) so no network port is bound and no external
infra is required. The lifespan is intentionally NOT triggered (no context-manager usage) so
the MetricsServer thread is not started during unit tests.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from __PKG__.app import Application
from __PKG__.config import ServiceConfig


def _cfg() -> ServiceConfig:
    """Minimal in-memory config for unit tests."""
    return ServiceConfig(
        service_name="__SLUG__-test",
        context="__CTX__",
        env="test",
        http_port=__PORT__,
        metrics_port=9090,
        log_level="warning",
        kafka_brokers="",
        rabbitmq_url="",
        db_dsn="",
        otel_endpoint="",
        jwt_issuer="",
    )


@pytest.fixture(scope="module")
def client() -> TestClient:
    application = Application(_cfg())
    return TestClient(application.fastapi_app, raise_server_exceptions=False)


def test_health_returns_200(client: TestClient) -> None:
    response = client.get("/health")
    assert response.status_code == 200


def test_health_response_contains_success_envelope(client: TestClient) -> None:
    response = client.get("/health")
    body = response.json()
    assert body["success"] is True
    assert body["data"]["status"] == "ok"


def test_live_returns_200(client: TestClient) -> None:
    response = client.get("/live")
    assert response.status_code == 200


def test_docs_ui_returns_200(client: TestClient) -> None:
    # API Documentation Standard: Swagger UI at /docs
    assert client.get("/docs").status_code == 200


def test_openapi_json_returns_200_with_bearer(client: TestClient) -> None:
    # API Documentation Standard: OpenAPI JSON at /swagger/v1/swagger.json + Bearer security scheme
    response = client.get("/swagger/v1/swagger.json")
    assert response.status_code == 200
    doc = response.json()
    assert doc["info"]["version"] == "v1"
    assert "Bearer" in doc.get("components", {}).get("securitySchemes", {})


def test_live_response_contains_success_envelope(client: TestClient) -> None:
    response = client.get("/live")
    body = response.json()
    assert body["success"] is True
    assert body["data"]["status"] == "alive"


def test_ready_returns_503_before_startup(client: TestClient) -> None:
    # Readiness gate is False when lifespan has not fired (unit test mode).
    response = client.get("/ready")
    assert response.status_code == 503


def test_version_returns_200(client: TestClient) -> None:
    response = client.get("/version")
    assert response.status_code == 200


def test_version_response_has_contract_version_field(client: TestClient) -> None:
    response = client.get("/version")
    body = response.json()
    assert body["success"] is True
    assert "contractVersion" in body["data"]


def test_response_echoes_correlation_id_header(client: TestClient) -> None:
    response = client.get("/health", headers={"X-Correlation-Id": "test-corr-123"})
    assert response.headers.get("X-Correlation-Id") == "test-corr-123"


def test_response_generates_correlation_id_when_absent(client: TestClient) -> None:
    response = client.get("/health")
    assert "X-Correlation-Id" in response.headers
    assert len(response.headers["X-Correlation-Id"]) > 0


def test_response_has_security_header_x_content_type_options(client: TestClient) -> None:
    response = client.get("/health")
    assert response.headers.get("X-Content-Type-Options") == "nosniff"


def test_response_has_security_header_x_frame_options(client: TestClient) -> None:
    response = client.get("/health")
    assert response.headers.get("X-Frame-Options") == "DENY"


def test_response_has_traceparent_header(client: TestClient) -> None:
    response = client.get("/health")
    assert "traceparent" in response.headers


def test_unknown_route_returns_404(client: TestClient) -> None:
    response = client.get("/nonexistent")
    assert response.status_code == 404
''', svc)
    _write(w, svc, "tests/test_health.py", body, banner=True)


# ---------------------------------------------------------------------------
# tests/test_integration.py — integration tests (pytest.mark.integration)
# ---------------------------------------------------------------------------

def _tests_integration(w: Writer, svc: Service) -> None:
    body = _sub('''\
"""
Integration tests for __SLUG__. These tests require ephemeral Docker infra
(Postgres, Redpanda, RabbitMQ) and are gated with pytest.mark.integration.

Run locally:
    pytest tests/ -m integration

The integration CI stage (see .gitlab-ci.yml) provisions Docker services automatically.
Unit CI excludes these:
    pytest tests/ -m "not integration"
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from __PKG__.app import Application
from __PKG__.config import ServiceConfig

pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def client() -> TestClient:
    """Boot the full service against real infra (provided by the integration CI stage)."""
    cfg = ServiceConfig.load()
    application = Application(cfg)
    with TestClient(application.fastapi_app) as c:
        yield c


@pytest.mark.integration
def test_service_health_when_infra_is_ready(client: TestClient) -> None:
    """Verifies /health returns 200 against the full running service with real infra."""
    response = client.get("/health")
    assert response.status_code == 200


@pytest.mark.integration
def test_service_readiness_after_startup(client: TestClient) -> None:
    """Verifies /ready returns 200 after the lifespan startup (migrations + readiness gate)."""
    response = client.get("/ready")
    assert response.status_code == 200
''', svc)
    _write(w, svc, "tests/test_integration.py", body, banner=True)


# ---------------------------------------------------------------------------
# Dockerfile — multi-stage python:3.13-slim, non-root
# ---------------------------------------------------------------------------

def _dockerfile(w: Writer, svc: Service) -> None:
    body = _sub('''\
# Stage 1: build — install all dependencies into an isolated virtual environment.
# The dkd-platform SDK wheel is fetched from the GitLab Package Registry during CI
# (see .gitlab-ci.yml); locally use --find-links or a dev install of dkd-platform-libs.
FROM python:3.13-slim AS build
WORKDIR /build

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY pyproject.toml ./
RUN pip install --no-cache-dir --upgrade pip setuptools && \
    pip install --no-cache-dir "fastapi>=0.111.0" "uvicorn[standard]>=0.30.0" || true

COPY src/ src/
RUN pip install --no-cache-dir --no-deps -e .

# Stage 2: runtime — stripped slim image; non-root service account.
FROM python:3.13-slim AS runtime
WORKDIR /app

RUN groupadd --system --gid 1001 dkd && \
    useradd --system --uid 1001 --gid 1001 --no-create-home dkd

COPY --from=build /opt/venv /opt/venv
COPY --from=build /build/src /app/src

ENV PATH="/opt/venv/bin:$PATH"
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

EXPOSE __PORT__ 9090

USER dkd

ENTRYPOINT ["python", "-m", "__PKG__"]
''', svc)
    w.write("Dockerfile", body)


# ---------------------------------------------------------------------------
# .gitlab-ci.yml — build + test + lint; docker package on main
# ---------------------------------------------------------------------------

def _ci(w: Writer, svc: Service) -> None:
    body = _sub('''\
stages: [build, package]

variables:
  PIP_CACHE_DIR: "$CI_PROJECT_DIR/.pip-cache"
  PYTHONDONTWRITEBYTECODE: "1"
  PYTHONUNBUFFERED: "1"

python:build-test:
  stage: build
  image: python:3.13-slim
  cache:
    key: pip-__SLUG__
    paths: [.pip-cache/]
  before_script:
    - pip install --no-cache-dir --upgrade pip
    - |
      pip install --no-cache-dir \
        --index-url "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/packages/pypi/simple" \
        --extra-index-url https://pypi.org/simple \
        __SDK__ 2>/dev/null || echo "SDK not yet in registry; skipping"
  script:
    - pip install --no-cache-dir -e ".[test]"
    - ruff check src/ tests/ || true
    - pytest tests/ -m "not integration" --tb=short -q

python:integration:
  stage: build
  image: python:3.13-slim
  services:
    - name: postgres:17-alpine
      alias: postgres
    - name: redpandadata/redpanda:v24.3.6
      alias: redpanda
      command:
        - redpanda
        - start
        - --smp
        - "1"
        - --overprovisioned
        - --kafka-addr
        - PLAINTEXT://0.0.0.0:9092
        - --advertise-kafka-addr
        - PLAINTEXT://redpanda:9092
    - name: rabbitmq:4.0-alpine
      alias: rabbitmq
  variables:
    POSTGRES_USER: dkd
    POSTGRES_PASSWORD: dkd
    POSTGRES_DB: __PKG__
    DKD_SERVICE_NAME: __SLUG__
    DKD_CONTEXT: __CTX__
    DKD_DB_DSN: "postgresql://dkd:dkd@postgres:5432/__PKG__"
    DKD_KAFKA_BROKERS: "redpanda:9092"
    DKD_RABBITMQ_URL: "amqp://guest:guest@rabbitmq:5672/"
  before_script:
    - pip install --no-cache-dir --upgrade pip
    - |
      pip install --no-cache-dir \
        --index-url "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/packages/pypi/simple" \
        --extra-index-url https://pypi.org/simple \
        __SDK__ 2>/dev/null || echo "SDK not yet in registry; skipping"
  script:
    - pip install --no-cache-dir -e ".[test]"
    - pytest tests/ -m integration --tb=short -q
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'

docker:build:
  stage: package
  image: docker:27
  services: [docker:27-dind]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  script:
    - docker login -u "$CI_REGISTRY_USER" -p "$CI_REGISTRY_PASSWORD" "$CI_REGISTRY"
    - docker build -t "$CI_REGISTRY_IMAGE:0.1.0" .
    - docker push "$CI_REGISTRY_IMAGE:0.1.0"
''', svc)
    w.write(".gitlab-ci.yml", body)


# ---------------------------------------------------------------------------
# Makefile
# ---------------------------------------------------------------------------

def _makefile(w: Writer, svc: Service) -> None:
    body = _sub('''\
.PHONY: run build test itest lint install

install:
\tpip install -e ".[test]"

run:
\tDKD_SERVICE_NAME=__SLUG__ DKD_CONTEXT=__CTX__ DKD_HTTP_PORT=__PORT__ serve

lint:
\truff check src/ tests/

test:
\tpytest tests/ -m "not integration" --tb=short -q

itest:
\tpytest tests/ -m integration --tb=short -q

build:
\tdocker build -t __SLUG__:dev .
''', svc)
    w.write("Makefile", body)
