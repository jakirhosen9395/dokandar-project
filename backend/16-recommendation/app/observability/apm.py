"""Elastic APM Starlette install — MUST be the LAST middleware added."""
from __future__ import annotations

import logging
import socket

from elasticapm.contrib.starlette import ElasticAPM, make_apm_client
from elasticapm.conf.constants import SPAN, ERROR
from elasticapm.processors import for_events
from fastapi import FastAPI

from app.config import settings


log = logging.getLogger("coupon.apm")

_DEFAULT_PROCESSORS = (
    "elasticapm.processors.sanitize_stacktrace_locals",
    "elasticapm.processors.sanitize_http_request_cookies",
    "elasticapm.processors.sanitize_http_headers",
    "elasticapm.processors.sanitize_http_wsgi_env",
    "elasticapm.processors.sanitize_http_request_body",
)


@for_events(SPAN)
def friendly_deps_processor(client, event):
    """Rename the auto-instrumented Qdrant HTTP destination from its raw IP:port to a friendly
    "qdrant" node in Dependencies + the service map (the qdrant-client exposes no friendlier name)."""
    try:
        svc = event.get("context", {}).get("destination", {}).get("service", {})
        res = svc.get("resource", "")
        if isinstance(res, str) and res.endswith(":6333"):
            svc["resource"] = "qdrant"
    except Exception:  # noqa: BLE001
        pass
    return event


@for_events(ERROR)
def drop_grpc_abort_errors(client, event):
    """A gRPC server returns a non-OK status to the client via context.abort(), which raises grpc's
    AbortError ('Locally aborted', culprit grpc._cython.cygrpc.abort). That is the idiomatic gRPC
    status-return mechanism — an expected protocol OUTCOME, not a defect — so drop it from error
    capture (scoped to the exact AbortError class; every other exception, incl. real qdrant/gRPC
    faults, still surfaces in the Errors tab)."""
    try:
        exc = event.get("exception") or {}
        if isinstance(exc, list):
            exc = exc[0] if exc else {}
        if isinstance(exc, dict) and exc.get("type") == "AbortError":
            return None  # drop
    except Exception:  # noqa: BLE001
        pass
    return event


def install(app: FastAPI) -> None:
    if not settings.apm_server_url:
        log.warning("APM_SERVER_URL empty — skipping APM install")
        return
    try:
        labels = {
            "service_name": settings.service_name,
            "tenant": settings.tenant,
            "env": settings.app_env,
            "env_version": settings.env_version,
            "hostname": socket.gethostname(),
        }
        client = make_apm_client({
            "SERVICE_NAME": settings.apm_service_name,
            "SERVER_URL": settings.apm_server_url,
            "SECRET_TOKEN": settings.apm_secret_token,
            "ENVIRONMENT": settings.app_env,
            "SERVICE_VERSION": settings.code_version,
            "TRANSACTION_SAMPLE_RATE": 1.0,
            "CAPTURE_BODY": "errors",
            "GLOBAL_LABELS": ",".join(f"{k}={v}" for k, v in labels.items()),
            "PROCESSORS": list(_DEFAULT_PROCESSORS) + ["app.observability.apm.friendly_deps_processor", "app.observability.apm.drop_grpc_abort_errors"],
        })
        app.add_middleware(ElasticAPM, client=client)
        log.info("APM installed — service=%s", settings.apm_service_name)
    except Exception:  # noqa: BLE001
        log.exception("APM install failed — continuing without APM")


def health_check() -> tuple[bool, str]:
    if not settings.apm_server_url:
        return False, "apm-url-empty"
    try:
        from urllib.parse import urlparse
        u = urlparse(settings.apm_server_url)
        host = u.hostname or ""
        port = u.port or (443 if u.scheme == "https" else 80)
        with socket.create_connection((host, port), timeout=2):
            return True, "otlp-reachable"
    except Exception as e:  # noqa: BLE001
        return False, f"unreachable:{type(e).__name__}"
