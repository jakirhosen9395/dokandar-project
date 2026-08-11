# `16-recommendation` — Personalization

> **Status — specified, NOT yet implemented.** This folder is a **scaffold**: the service code
> (`Dockerfile`, `env/`, `test.sh`, application source) does **not** exist yet. The authoritative spec is
> [`../README.md`](../README.md) (the catalog) + [`../../README.md`](../../README.md) §6/§7/§10 +
> [`../../architecture.md`](../../architecture.md) §9. **On any conflict, the README wins — re-verify.**

## Identity

| Field | Value |
| --- | --- |
| Service | `16-recommendation` |
| Domain | Intelligence & Analytics |
| Language · framework | Python 3.14 · FastAPI + PyTorch |
| Primary datastore(s) | Qdrant + Redis 8 (DB14) + PostgreSQL 18 |
| `SERVICE_PORT` (in-container) | 8000 (uvicorn) |
| gRPC port | 50051 |
| External ports | REST `10016` · gRPC `20016` |
| **`/ready` hard-gate** | **PostgreSQL** (the interaction-log writer); does NOT gate on Qdrant/Redis (popularity fallback serves a feed) |

## Bounded context

Personalized discovery — "for you", "frequently bought together", "shoppers who viewed this also viewed", cold-start — served from user/product/shop embeddings via **Qdrant ANN**. A business-rule reranker applies BD nuances: **same-district boost**, **COD-preference boost**, suspended-shop exclusion. Eventually consistent, read-optimized.

## Data ownership

Qdrant: `dokandar_user_embeddings` (768-d), `dokandar_product_embeddings` (768-d), `dokandar_shop_embeddings` (256-d). PostgreSQL owns the interaction log + `consumer_offsets`. Redis DB14 holds the served-feed cache.

## Synchronous API

- **REST:** `/api/v1/recommendation/…`: `GET /feed/me`, `/similar/{id}`, `/cross-sell`, admin retrain
- **gRPC exposed:** feed-serving @50051 (low-latency in-fleet reads)
- **gRPC called:** minimal — reads its own Qdrant/Redis

## Events & queues

- **Emits (Kafka):** **nothing**
- **Consumes (Kafka):** `dokandar.product.changed` (re-embed), `dokandar.order.placed` (co-purchase), `dokandar.review.posted`, + search query logs
- **RabbitMQ / NATS:** none — nightly retrain (sentence-transformers + PyTorch, Airflow/Temporal + Ray) bulk-upserts Qdrant off the request path

## Operational notes

- **Idempotency:** offsets in `consumer_offsets`; idempotent projection; retrain guarded against double-trigger.
- **Resilience:** Qdrant down/cold → fall back to a **popularity/trending feed** (precomputed, Redis-cached); serving is pre-computed embeddings + ANN + feed cache, **no inline inference**.
- **Security:** embeddings encode behavioral PII — treat vectors as sensitive, never expose another user's feed; self-hosted models.

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
