# `08-review` — Reviews, Q&A, Ratings

> **Status — specified, NOT yet implemented.** This folder is a **scaffold**: the service code
> (`Dockerfile`, `env/`, `test.sh`, application source) does **not** exist yet. The authoritative spec is
> [`../README.md`](../README.md) (the catalog) + [`../../README.md`](../../README.md) §6/§7/§10 +
> [`../../architecture.md`](../../architecture.md) §9. **On any conflict, the README wins — re-verify.**

## Identity

| Field | Value |
| --- | --- |
| Service | `08-review` |
| Domain | Commerce Core |
| Language · framework | Kotlin 2.4 · Ktor 3.5 |
| Primary datastore(s) | PostgreSQL 18 + Elasticsearch 9.4 (no Redis) |
| `SERVICE_PORT` (in-container) | 8080 |
| gRPC port | 50051 |
| External ports | REST `10008` · gRPC `20008` |
| **`/ready` hard-gate** | **PostgreSQL** (ES does NOT gate) |

## Bounded context

Customer reviews, shopkeeper replies, helpful votes, abuse reports with auto-hide, admin moderation, and incremental rating aggregates. Bilingual free text. **Verified-purchase enforcement** from a local projection of order events; a 7-day edit window.

## Data ownership

PostgreSQL `dokandar_review_<env>` (sole writer): `reviews`, `review_replies|votes|reports`, `rating_aggregates`, `purchase_eligibility` (projected from order events), `outbox`. Elasticsearch `dokandar-reviews` for review search only.

## Synchronous API

- **REST:** `/api/v1/review/…`: review CRUD, reply/vote/report, admin hide/restore, `GET /aggregate`
- **gRPC exposed:** `ReviewQuery.HasPurchased` @50051 — answered from its OWN `purchase_eligibility` projection (does NOT call `Order.HasPurchased`)
- **gRPC called:** none

## Events & queues

- **Emits (Kafka):** `dokandar.review.*` (incl. `review.posted`), `dokandar.rating.aggregate.changed`
- **Consumes (Kafka):** `dokandar.order.delivered`, `dokandar.order.refunded` → `purchase_eligibility`
- **RabbitMQ / NATS:** none

## Operational notes

- **Idempotency:** one-review-per-`(user, product/order)` via a PG UNIQUE constraint → idempotent submission. No Redis (ES updated async after the PG write).
- **Resilience:** ES degraded → serve CRUD/votes/aggregates from Postgres (only review *search* degrades).
- **Security:** verified-purchase gating prevents spam; author-only edit within 7 days; admin scopes gate hide/restore.

Plus the **universal contract** (all 18): the five endpoints (`/ready`, `/health`, `/data`, `/docs`,
`/metrics`) byte-identical with the identity block; verify-only RS256 + constant-time
`INTERNAL_SERVICE_TOKEN`; transactional outbox; MongoDB + Elasticsearch log sinks + Elastic APM +
Prometheus (non-gating). Full contract: [`../../README.md`](../../README.md) §13–§14 and
[`../../architecture.md`](../../architecture.md) §10.

## Build checklist (when this service is implemented — none of it exists yet)

- [ ] `Dockerfile` — multi-stage distroless/slim, non-root **uid 10001**, `HEALTHCHECK → GET /ready`, `EXPOSE` the idiomatic `SERVICE_PORT` (+ gRPC `50051`/`9090`)
- [ ] `env/init-env.sh` + `.env.<dev|stage|prod>` (12-factor; **fail-fast** on empty `JWT_PUBLIC_KEY_B64` / `INTERNAL_SERVICE_TOKEN` / `SERVICE_NAME` under stage/prod)
- [ ] the **five endpoints** with the byte-identical identity block + the `X-Request-Id`-correlated error envelope
- [ ] `test.sh` — contract smoke test that curls all five endpoints
- [ ] `data/<tenant>/result.json` — the `/data` snapshot (bind-mounted read-only at `/app/data`)
- [ ] per-service docs: `OPERATIONS.md`, `ARCHITECTURE.md`, `BUSINESS_LOGIC.md`, `SECURITY.md`, `docs/adr/`

## See also

- [`../README.md`](../README.md) — the 18-service catalog (identity, ports, the per-service infra matrix).
- [`../../architecture.md`](../../architecture.md) — **§9** this service in full detail; **§21** the event + gRPC cross-service anchor.
- [`../../utility/`](../../utility/README.md) — the backing infrastructure this service connects to (+ its connectivity matrix).
