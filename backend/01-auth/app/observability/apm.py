"""Elastic APM integration.

Adds runtime-context detection (docker / kubernetes / native) so the agent
ships every transaction with enough metadata for Kibana APM to identify
how this instance is running:

  * `service.node.name` — set explicitly to the container ID (docker),
    the pod name (k8s), or the hostname (native). Kibana APM groups
    instances by this in the **Service overview → Instances** view.
  * `labels.runtime` — one of `docker` / `kubernetes` / `native`.
    Searchable, groupable, dashboardable.
  * `labels.container_id` (docker) or `labels.k8s_pod_name` /
    `labels.k8s_namespace` / `labels.k8s_node_name` (k8s).

Why labels and not the top-level `container.id` / `kubernetes.*` fields:
elastic-apm-python's auto-detector reads `/proc/self/cgroup`, which on
Ubuntu 26.04 cgroup v2 returns the unified `0::/` and the agent can't
extract a container ID from it. Labels are the public-API path; they
give the same UX in Kibana (filter, group, dashboard) — only the
"Container" sidebar icon is missing, which doesn't affect any query or
alert path.
"""
from __future__ import annotations
import logging
import os
import socket
from urllib.parse import urlparse

from elasticapm.contrib.starlette import ElasticAPM, make_apm_client

from app.config import settings

log = logging.getLogger("auth.apm")
_apm_client = None


def _detect_runtime() -> tuple[str, str, dict]:
    """Return (runtime_kind, service_node_name, labels_dict).

    Detection order: kubernetes -> docker -> native. K8s is checked
    first because a pod runs inside a docker (or other) container, but
    we want it tagged as `kubernetes`, not `docker`.
    """
    labels: dict[str, str] = {}

    if os.environ.get("KUBERNETES_SERVICE_HOST"):
        # K8s clusters set KUBERNETES_SERVICE_HOST in every pod. Pod
        # identity comes from env vars the manifest must inject via
        # downwardAPI (`fieldRef`): POD_NAME / POD_NAMESPACE / NODE_NAME.
        # Falls back to HOSTNAME (set to pod name by k8s) if the manifest
        # didn't add the downward fields.
        pod  = os.environ.get("POD_NAME") or os.environ.get("HOSTNAME") or socket.gethostname()
        ns   = os.environ.get("POD_NAMESPACE", "")
        node = os.environ.get("NODE_NAME", "")
        labels["runtime"] = "kubernetes"
        if pod:  labels["k8s_pod_name"]  = pod
        if ns:   labels["k8s_namespace"] = ns
        if node: labels["k8s_node_name"] = node
        return "kubernetes", pod, labels

    if os.path.exists("/.dockerenv"):
        # /.dockerenv is a sentinel file the docker engine creates in
        # every container. /etc/hostname inside a docker container is
        # the container ID (unless the user overrode it via --hostname).
        try:
            with open("/etc/hostname") as f:
                cid = f.read().strip()
        except Exception:
            cid = socket.gethostname()
        labels["runtime"] = "docker"
        labels["container_id"] = cid
        labels["container_runtime"] = "docker"
        return "docker", cid, labels

    # Bare native run on a VM or laptop.
    host = socket.gethostname()
    labels["runtime"] = "native"
    return "native", host, labels


def _labels_to_kv_string(labels: dict[str, str]) -> str:
    """elasticapm's GLOBAL_LABELS env-var format: comma-separated key=value.
    No commas or equals signs inside values; container IDs and pod names
    are safe (alphanumeric + dashes/dots)."""
    return ",".join(f"{k}={v}" for k, v in labels.items() if v)


def get_apm_client():
    global _apm_client
    if _apm_client is None:
        runtime_kind, node_name, labels = _detect_runtime()
        log.info(
            "apm runtime=%s node=%s labels=%s",
            runtime_kind, node_name, labels,
        )
        _apm_client = make_apm_client({
            "SERVICE_NAME":      settings.apm_service_name,
            "SERVER_URL":        settings.apm_server_url,
            "SECRET_TOKEN":      settings.apm_secret_token,
            "ENVIRONMENT":       settings.app_env,
            "SERVICE_VERSION":   settings.code_version,
            "SERVICE_NODE_NAME": node_name,
            "GLOBAL_LABELS":     _labels_to_kv_string(labels),
        })
    return _apm_client


def install(app):
    try:
        client = get_apm_client()
        app.add_middleware(ElasticAPM, client=client)
        log.info("apm installed (server=%s)", settings.apm_server_url)
    except Exception as e:
        log.warning("apm install failed: %s", e)


def health_check(timeout_s: float = 2.0) -> tuple[bool, str]:
    """TCP-level reachability check for the APM server URL.

    Returns (reachable, detail). Used by /ready and /health dep checks.
    Cheap — we don't want to spam the APM server with deep probes.
    """
    try:
        u = urlparse(settings.apm_server_url)
        host = u.hostname or "localhost"
        port = u.port or (443 if u.scheme == "https" else 80)
        with socket.create_connection((host, port), timeout=timeout_s):
            return True, f"{host}:{port} tcp-ok"
    except Exception as e:
        return False, str(e)[:80]
