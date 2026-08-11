"""
dkdscaffold.blueprint — the CANONICAL service blueprint.

One blueprint defines the architecture and capabilities every generated service has, regardless of
runtime. Each runtime emitter realises this contract idiomatically. No business logic lives here or
in any generated service — this is infrastructure only.
"""
from __future__ import annotations
from dataclasses import dataclass

# The five sanctioned runtimes (ADR-011). Names are the scaffolder's --lang values.
RUNTIMES = ("go", "java", "csharp", "python", "node")

# The capability contract — every generated service supports ALL of these without manual coding.
CAPABILITIES = (
    "standard-structure",        # hexagonal: domain <- application <- adapters
    "config-loading",
    "dependency-injection",
    "graceful-shutdown",
    "startup-validation",
    "http-health", "http-readiness", "http-liveness", "http-version",
    "structured-logging",
    "metrics",                   # Prometheus /metrics
    "distributed-tracing",       # OpenTelemetry
    "correlation-ids",
    "request-logging",
    "jwt-authentication",
    "authorization",
    "security-headers",
    "input-validation",
    "exception-handling",
    "kafka-bootstrap",
    "rabbitmq-bootstrap",
    "event-publisher",           # abstraction only — no business events
    "event-consumer",            # abstraction only — no business events
    "db-abstraction",
    "migrations",
    "repository-base",           # base only — no business repositories
    "transaction-helpers",
    "unit-tests",
    "integration-tests",
    "testcontainers",
    "dockerfile",
    "docker-compose",
    "helm-chart",
    "k8s-manifests",
    "gitlab-ci",
)

# Informational: each frozen bounded context's runtime (from CLAUDE.md / data-stores.yaml). The
# scaffolder takes --lang explicitly, but can default it from --context.
CONTEXT_RUNTIME = {
    "identity": "csharp", "catalog": "go", "custody": "go", "provenance": "go", "inventory": "go",
    "b2c": "node", "b2b": "java", "finance": "java", "logistics": "go", "fraud": "python",
    "government": "csharp", "analytics": "python", "platform": "go",
    "edge-gateway": "go", "bff": "node",
}

# Default consumed SDK (dkd-platform-libs) coordinate per runtime — what the generated service imports.
SDK_COORDINATE = {
    "go": "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go",
    "java": "com.dokandar:dkd-platform-sdk:1.0.0",
    "csharp": "Dkd.Platform",
    "python": "dkd-platform",
    "node": "@dokandar/platform-sdk",
}

# HTTP port convention for generated services (overridable via --port).
DEFAULT_HTTP_PORT = 8080


@dataclass(frozen=True)
class Service:
    """The parameters for one generated service skeleton (no business data)."""
    name: str            # e.g. "catalog-svc"
    context: str         # e.g. "catalog" (one of the 13 bounded contexts)
    runtime: str         # one of RUNTIMES
    http_port: int = DEFAULT_HTTP_PORT
    group: str = "final-year-project3354127"

    @property
    def slug(self) -> str:
        return self.name.replace("_", "-")

    @property
    def pkg(self) -> str:
        """A language-neutral package token, e.g. catalog-svc -> catalogsvc."""
        return self.name.replace("-", "").replace("_", "")

    @property
    def sdk(self) -> str:
        return SDK_COORDINATE[self.runtime]
