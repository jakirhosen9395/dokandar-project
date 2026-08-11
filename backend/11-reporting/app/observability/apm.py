"""Elastic APM Starlette install — MUST be the LAST middleware added."""
from __future__ import annotations

import logging
import socket

from elasticapm.contrib.starlette import ElasticAPM, make_apm_client
from fastapi import FastAPI

from app.config import settings


log = logging.getLogger("coupon.apm")


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
