#!/usr/bin/env python3
"""
dev-infra CI invariant check. Validates compose.yaml is well-formed and that the structural invariants
of the development substrate hold — including the ADR-026 search/observability network isolation.
Run by the dkd-infra pipeline (no Docker daemon needed). Exit non-zero on any violation.
"""
import sys
import yaml

REQUIRED_SERVICES = {
    "postgres", "redis", "kafka", "kafka-ui", "schema-registry", "rabbitmq",
    "opensearch", "rustfs", "apm-elasticsearch", "apm-server", "apm-kibana",
}
errors = []


def main() -> int:
    doc = yaml.safe_load(open("dev-infra/compose.yaml", encoding="utf-8"))
    services = doc.get("services", {})
    networks = doc.get("networks", {})

    missing = REQUIRED_SERVICES - set(services)
    if missing:
        errors.append("missing services: %s" % sorted(missing))

    for n in ("dokandar_dev", "dokandar_obs"):
        if n not in networks:
            errors.append("missing network: %s" % n)

    def nets(svc):
        v = services.get(svc, {}).get("networks", [])
        return set(v.keys()) if isinstance(v, dict) else set(v or [])

    # ADR-026 — search vs observability isolation invariants
    if nets("opensearch") != {"dokandar_dev"}:
        errors.append("opensearch must be ONLY on dokandar_dev (business search), got %s" % nets("opensearch"))
    if nets("apm-elasticsearch") != {"dokandar_obs"}:
        errors.append("apm-elasticsearch must be ONLY on dokandar_obs (observability), got %s" % nets("apm-elasticsearch"))
    if nets("apm-kibana") != {"dokandar_obs"}:
        errors.append("apm-kibana must be ONLY on dokandar_obs, got %s" % nets("apm-kibana"))
    if nets("apm-server") != {"dokandar_dev", "dokandar_obs"}:
        errors.append("apm-server must bridge BOTH networks, got %s" % nets("apm-server"))

    # every stateful service must declare a healthcheck (readiness contract)
    for svc in ("postgres", "redis", "kafka", "schema-registry", "rabbitmq", "opensearch", "rustfs"):
        if "healthcheck" not in services.get(svc, {}):
            errors.append("%s missing healthcheck" % svc)

    if errors:
        print("dev-infra compose INVARIANTS FAILED:")
        for e in errors:
            print("  ✗ " + e)
        return 1
    print("dev-infra compose invariants OK: %d services, isolation (ADR-026) enforced, healthchecks present"
          % len(services))
    return 0


if __name__ == "__main__":
    sys.exit(main())
