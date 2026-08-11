# Architecture notes — dkd-infra

> Target structure and binding rules. **No code yet** (Stage 0.1). Implementation lands in Stage 0.

## Hexagonal layout (target)

Dependency rule: **`domain ← application ← adapters`** — the domain imports nothing outward
(EF §13.1.2; CI architecture-fitness functions enforce this).

```
domain ← application ← adapters
```

## Rules this context must uphold

- Enforcement labels: **R2, R6**.
- **R6** — all cross-context integration via the Kafka Published Language (or declared OHS gRPC);
  never touch another context's store. RabbitMQ is intra-context only.
- **Effectively-once** — transactional outbox + consumer inbox (dedup on `event_id`) + per-topic DLQ;
  money/custody/inventory poison messages are park-and-frozen, never dropped.
- **Types** — money `int64` poisha (float/decimal/string banned, lint-enforced); time `int64` ms UTC;
  IDs UUIDv7 with canonical prefixes; raw NID never stored (`SHA-256(rawNID)` only).
- **APIs** — external REST `/v1` (envelope `{success,data,error,meta}`, cursor pagination, RFC-7807
  `problem+json`, `Idempotency-Key` on unsafe/money/custody writes); internal gRPC OHS only.

## Canonical references (by ID — never restated here)

- Domain detail, aggregates, events, CustodyHash → `DOKANDAR-Domain-Model.md`.
- Service build/messaging/security → `DOKANDAR-Service-Architecture.md` (Ch.27 hardening for Tier-0).
- Topics/persistence → `dkd-contracts-spine/messaging.yaml`, `data-stores.yaml`.
- Engineering standards → `Engineering-Foundation.md`; design rules → `constitution-index/design-rules-R1-R8.md`.

Trace: R6, EF§13.1.2, DM type-conventions

## Search vs Observability engines (ADR-026)

DOKANDAR uses two Elasticsearch-family engines for two **separate, isolated** purposes:

- **OpenSearch — business search infrastructure (canonical).** All business services that require search
  use OpenSearch. It is never replaced by Elasticsearch.
- **Elasticsearch — developer observability ONLY (ELK/APM stack).** Used for tracing, APM, log analysis,
  and developer diagnostics via APM Server + Kibana. Business services must **never** use it for application search.

In the Docker development substrate these live on **separate networks** (`dokandar_dev` business vs
`dokandar_obs` observability); only APM Server bridges them, so business services cannot reach the
observability Elasticsearch (verified by execution). On the future Kubernetes platform this becomes a
**NetworkPolicy**. This **does not change** the DOKANDAR target architecture — see ADR-026.
