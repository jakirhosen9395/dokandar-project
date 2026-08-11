---
id: ADR-026
title: Search vs Observability engine separation — OpenSearch (business) vs Elasticsearch (observability)
status: Accepted
date: 2026-06-30
relates-to: [ADR-025, DOKANDAR-System-Architecture §8 persistence map, data-stores.yaml, R6]
---

# ADR-026 — OpenSearch is business search; Elasticsearch is developer observability only

## Status
Accepted. **Does not change the DOKANDAR target architecture** — it makes an existing boundary explicit
and enforces it, so it cannot drift.

## Context
The development substrate (ADR-025) reuses two upstream references that both ship an
Elasticsearch-family engine:
- the **utilities** repo (`utility2/03_Elasticsearch`) — a generic search engine, and
- the **elastic-apm-stack** repo — Elasticsearch + Kibana + APM Server for developer observability.

DOKANDAR's canonical search engine, however, is **OpenSearch** (System-Architecture §8 persistence map;
`dkd-contracts-spine/data-stores.yaml`). Without an explicit rule, a future contributor could wire a
business service's search to the observability Elasticsearch (because it is "right there"), silently
violating the architecture and coupling business behaviour to a developer-diagnostics system.

## Decision
Two **distinct, isolated** engines with **non-overlapping responsibilities**:

| Engine | Purpose | Who uses it | Where (dev substrate) |
|---|---|---|---|
| **OpenSearch** | **Business search** — the canonical DOKANDAR search platform | Business services (Catalog/Inventory/etc.) | `opensearch` service, `search` profile, **`dokandar_dev`** network |
| **Elasticsearch** | **Developer observability ONLY** — APM/traces/metrics/logs (ELK/APM) | Operators/developers (via APM Server + Kibana) | `apm-elasticsearch`+`apm-kibana`, `observability` profile, **`dokandar_obs`** network |

Hard rules:
1. **All business search uses OpenSearch.** Do not replace OpenSearch with Elasticsearch.
2. **Business services MUST NEVER depend on the observability Elasticsearch for application search.**
3. The ELK/APM Elasticsearch is reachable only by **APM Server** and **Kibana**.

## Enforcement (not just documentation)
- **Network isolation.** `apm-elasticsearch` and `apm-kibana` sit on a dedicated **`dokandar_obs`**
  network. Business services and OpenSearch sit on **`dokandar_dev`**. The two planes are bridged ONLY by
  **APM Server** (on both networks): services send traces to `apm-server:8200`; APM Server alone writes to
  `apm-elasticsearch:9200`. A business container therefore **cannot even resolve/reach**
  `apm-elasticsearch`. This maps directly to a Kubernetes **NetworkPolicy** on the future platform.
- **No host port** is published for `apm-elasticsearch` (internal to the observability plane).
- Naming makes intent unmistakable: `opensearch` (business) vs `apm-elasticsearch` (observability).

## Upstream reuse boundary
Reuse the **utilities** and **elastic-apm-stack** repositories as-is; **do not modify them upstream**.
DOKANDAR-specific composition (OpenSearch substitution for business search, the two-network split, profiles)
lives **only** inside `dkd-infra/dev-infra`.

## Consequences
- **Positive:** the architectural boundary is structurally enforced, not just convention; the k8s migration
  inherits it as a NetworkPolicy; no accidental coupling of business search to observability.
- **Cost:** APM Server is dual-homed (the deliberate, sole bridge). Acceptable and explicit.
- **Migration:** unchanged target architecture — OpenSearch remains the business search platform; the ELK
  stack remains a separate developer-observability concern.
