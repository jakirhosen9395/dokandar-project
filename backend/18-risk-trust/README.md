# `18-risk-trust` — Fraud & COD Risk

> **Status — specified, NOT yet implemented.** This folder is a **scaffold**: the service code
> (`Dockerfile`, `env/`, `test.sh`, application source) does **not** exist yet. The authoritative spec is
> [`../README.md`](../README.md) (the catalog) + [`../../README.md`](../../README.md) §6/§7/§10 +
> [`../../architecture.md`](../../architecture.md) §9. **On any conflict, the README wins — re-verify.**

## Identity

| Field | Value |
| --- | --- |
| Service | `18-risk-trust` |
| Domain | Intelligence & Analytics |
| Language · framework | Python 3.14 · FastAPI + scikit-learn / vLLM |
| Primary datastore(s) | ScyllaDB + Qdrant + PostgreSQL 18 (no Redis) |
| `SERVICE_PORT` (in-container) | 8000 (uvicorn) |
| gRPC port | 50051 |
| External ports | REST `10018` · gRPC `20018` |
| **`/ready` hard-gate** | **PostgreSQL** (does NOT gate on ScyllaDB/Qdrant — sits on the checkout hot path; rule-based fallback produces a score) |

## Bounded context

The fraud, abuse, and credit-scoring engine: every checkout scored for fraud and every COD order for **refusal-on-delivery probability** (a chronic BD cost given ~70% COD). Blends rule signals (velocity, device fingerprint, geolocation, BIN-mismatch) with ML over user-shop-device graph embeddings, serving **`Risk.ScoreCheckout|ScoreCOD`** at **< 100 ms p99** on the hot path.

## Data ownership

ScyllaDB `dokandar_risk`: `user_events`, `device_fingerprints`, `risk_decisions`, `velocity_counters` (partitioned/clustered `(user_id, ts)`). Qdrant `dokandar_risk_graph_embeddings` for ANN neighbor lookup. PostgreSQL for rules/overrides (durable, audited).

## Synchronous API

- **REST:** `/api/v1/risk/…`: `POST /score/checkout` (<100 ms p99), `/score/cod`, `/score/review`, admin rules CRUD
- **gRPC exposed:** `Risk.ScoreCheckout`, `Risk.ScoreCOD` @50051 (called by `06-cart` + `13-order`)
- **gRPC called:** none on the score path

## Events & queues

- **Emits (Kafka):** `dokandar.risk.*` (decisions/flags)
- **Consumes (Kafka):** **essentially all platform events** — `order.*`, `payment.*`, `user.*`, `kyc.*`, `product.changed`, `review.*` — and notably **`dokandar.shipment.failed_delivery` (←17), the COD-refusal label**
- **RabbitMQ / NATS:** none — nightly retrain (scikit-learn + XGBoost; vLLM batch enrichment) off the Kafka stream

## Operational notes

- **Idempotency:** no Redis — the fast counters *are* ScyllaDB `velocity_counters` (sub-ms); idempotent event projection (event-id keyed) so replays don't inflate velocity.
- **Resilience:** Qdrant/model down → **pure rule-based scoring**; on total degradation **fail toward a conservative hold/manual-review**, never auto-approve fraud. **vLLM/LLM never runs inline** (cannot hit 100 ms).
- **Security:** highest-sensitivity — fingerprints/graphs/KYC-derived signals stay self-hosted (data-localization); **never leak score internals/thresholds** to clients (only allow/review/deny).

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
