# `05-search` — Discovery (CQRS read side)

> **Status — specified, NOT yet implemented.** This folder is a **scaffold**: the service code
> (`Dockerfile`, `env/`, `test.sh`, application source) does **not** exist yet. The authoritative spec is
> [`../README.md`](../README.md) (the catalog) + [`../../README.md`](../../README.md) §6/§7/§10 +
> [`../../architecture.md`](../../architecture.md) §9. **On any conflict, the README wins — re-verify.**

## Identity

| Field | Value |
| --- | --- |
| Service | `05-search` |
| Domain | Commerce Core |
| Language · framework | Rust 1.96 · Axum + sqlx |
| Primary datastore(s) | Elasticsearch 9.4 + PostgreSQL 18 (no Redis) |
| `SERVICE_PORT` (in-container) | 8080 |
| gRPC port | — |
| External ports | REST `10005` · gRPC — |
| **`/ready` hard-gate** | **PostgreSQL** (ES does NOT gate — PG `tsvector` fallback preserves single-request capability) |

## Bounded context

The customer-facing **read projection**: bilingual full-text search (separate Bangla/English `tsvector`), faceted browse, "shops near me", autocomplete (prefix + trigram), trending. **Consumer-only** — the sole writers are four Kafka projector tasks. The CQRS read side paired with `04-catalog`.

## Data ownership

PostgreSQL `dokandar_search_<env>`: `*_view` projections, `trending_counters`, `query_logs`, `consumer_offsets` (idempotent upsert keyed by topic/partition/offset). Elasticsearch `dokandar-products`, `dokandar-shops`. No Redis. Eventually consistent — projection lag is the defining SLO.

## Synchronous API

- **REST:** `/api/v1/search/…`: `products`, `autocomplete`, `shops`, `trending`, `categories/tree`, admin reindex
- **gRPC exposed:** none
- **gRPC called:** none

## Events & queues

- **Emits (Kafka):** **nothing**
- **Consumes (Kafka):** exactly four: `dokandar.product.changed`, `dokandar.shop.changed`, `dokandar.category.changed`, `dokandar.order.placed` (→ `trending_counters`)
- **RabbitMQ / NATS:** none

## Operational notes

- **Idempotency:** offset-based — each projector commits `consumer_offsets` in the same tx as the view upsert → exactly-once-effective. No Redis (the `*_view` tables are the cache).
- **Resilience:** ES degraded → fall back to Postgres `*_view` + `tsvector`/`pg_trgm` (faceting/ranking drop, discovery stays up); report in `/health`, not `/ready`.
- **Security:** public read endpoints (PII-stripped); `query_logs` carry no `user_id` in metric labels.

Plus the **universal contract** (all 18): the five endpoints (`/ready`, `/health`, `/data`, `/docs`,
`/metrics`) byte-identical with the identity block; verify-only RS256 + constant-time
`INTERNAL_SERVICE_TOKEN`; transactional outbox; MongoDB + Elasticsearch log sinks + Elastic APM +
Prometheus (non-gating). Full contract: [`../../README.md`](../../README.md) §13–§14 and
[`../../architecture.md`](../../architecture.md) §10.

## Build checklist (when this service is implemented — none of it exists yet)

- [ ] `Dockerfile` — multi-stage distroless/slim, non-root **uid 10001**, `HEALTHCHECK → GET /ready`, `EXPOSE` the idiomatic `SERVICE_PORT`
- [ ] `env/init-env.sh` + `.env.<dev|stage|prod>` (12-factor; **fail-fast** on empty `JWT_PUBLIC_KEY_B64` / `INTERNAL_SERVICE_TOKEN` / `SERVICE_NAME` under stage/prod)
- [ ] the **five endpoints** with the byte-identical identity block + the `X-Request-Id`-correlated error envelope
- [ ] `test.sh` — contract smoke test that curls all five endpoints
- [ ] `data/<tenant>/result.json` — the `/data` snapshot (bind-mounted read-only at `/app/data`)
- [ ] per-service docs: `OPERATIONS.md`, `ARCHITECTURE.md`, `BUSINESS_LOGIC.md`, `SECURITY.md`, `docs/adr/`

## See also

- [`../README.md`](../README.md) — the 18-service catalog (identity, ports, the per-service infra matrix).
- [`../../architecture.md`](../../architecture.md) — **§9** this service in full detail; **§21** the event + gRPC cross-service anchor.
- [`../../utility/`](../../utility/README.md) — the backing infrastructure this service connects to (+ its connectivity matrix).
