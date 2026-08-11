# `11-reporting` — Analytics & Regulatory

> **Status — specified, NOT yet implemented.** This folder is a **scaffold**: the service code
> (`Dockerfile`, `env/`, `test.sh`, application source) does **not** exist yet. The authoritative spec is
> [`../README.md`](../README.md) (the catalog) + [`../../README.md`](../../README.md) §6/§7/§10 +
> [`../../architecture.md`](../../architecture.md) §9. **On any conflict, the README wins — re-verify.**

## Identity

| Field | Value |
| --- | --- |
| Service | `11-reporting` |
| Domain | Intelligence & Analytics |
| Language · framework | Python 3.14 · FastAPI + asyncpg |
| Primary datastore(s) | ClickHouse 26.3 LTS + PostgreSQL 18 (+ Redis DB11) |
| `SERVICE_PORT` (in-container) | 8000 (uvicorn) |
| gRPC port | — |
| External ports | REST `10011` · gRPC — |
| **`/ready` hard-gate** | **PostgreSQL** (does NOT gate on ClickHouse — CH endpoints fail per-request `503`) |

## Bounded context

The analytics warehouse: sub-second OLAP over GMV, AOV, take-rate, payment-mix, refund-rate, per-shop KPIs, plus the regulatory export surface — the monthly **NBR VAT return (mushak-6.3)** and the **BTRC DBID quarterly summary**, generated from its own fact tables, never by querying source services. A pure read-projection consumer.

## Data ownership

ClickHouse `dokandar_analytics`: `fact_order`, `fact_order_state_change`, `fact_payment`, `fact_payout` (month-partitioned, sort key `(tenant, shop_id, placed_at)`). PostgreSQL `dokandar_reporting_<env>`: the same canonical facts + `consumer_offsets` (the durable copy that anchors export integrity + survives a ClickHouse rebuild).

## Synchronous API

- **REST:** `/api/v1/reporting/…`: platform/per-shop KPIs, rollups, payment-mix, `…/exports/nbr-vat`, `…/exports/btrc-dbid`
- **gRPC exposed:** none (REST/analytics-only)
- **gRPC called:** none

## Events & queues

- **Emits (Kafka):** **nothing**
- **Consumes (Kafka):** `dokandar.order.*`, `dokandar.payment.*` → fact tables (two-tier: idempotent PG upsert, then Flink/bulk loader → ClickHouse)
- **RabbitMQ / NATS:** none

## Operational notes

- **Idempotency:** each fact row keyed by source event id → replays are upserts, never double-counts (a double-counted GMV row corrupts a VAT return).
- **Resilience:** ClickHouse down → OLAP endpoints `503` individually, but Postgres holds canonical facts so exports/core KPIs degrade rather than fail; ClickHouse is **rebuildable** from `consumer_offsets`.
- **Security:** expose aggregates not raw rows; regulatory exports read the **Postgres canonical copy under a snapshot**, reconciling to the ledger.

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
