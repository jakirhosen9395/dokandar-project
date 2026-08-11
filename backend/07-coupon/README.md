# `07-coupon` — Discount Engine

> **Status — specified, NOT yet implemented.** This folder is a **scaffold**: the service code
> (`Dockerfile`, `env/`, `test.sh`, application source) does **not** exist yet. The authoritative spec is
> [`../README.md`](../README.md) (the catalog) + [`../../README.md`](../../README.md) §6/§7/§10 +
> [`../../architecture.md`](../../architecture.md) §9. **On any conflict, the README wins — re-verify.**

## Identity

| Field | Value |
| --- | --- |
| Service | `07-coupon` |
| Domain | Commerce Core |
| Language · framework | C# / .NET 10 LTS · ASP.NET Core Minimal API + EF Core 10 |
| Primary datastore(s) | PostgreSQL 18 + Redis 8 (DB6) |
| `SERVICE_PORT` (in-container) | 8080 |
| gRPC port | 9090 ¹ |
| External ports | REST `10007` · gRPC `20007 ¹` |
| **`/ready` hard-gate** | **PostgreSQL** (Redis-down stays ready via PG recompute) |

## Bounded context

Coupon templates (percent/fixed/min-spend/first-order), the `draft → approved → active → revoked/expired` lifecycle with **four-eyes approval**, and **festival campaigns** (Eid-ul-Fitr, Eid-ul-Azha, Pohela Boishakh, Durga Puja, 16 December) with per-shop opt-in. Authority on whether/how-much a discount applies, evaluated synchronously during checkout.

## Data ownership

PostgreSQL `dokandar_coupon_<env>` (sole writer): `coupons`, `coupon_redemptions` (UNIQUE `(coupon_id, order_id)`), `festivals`, `festival_shops`, `outbox`. Redis DB6 caches active coupons.

## Synchronous API

- **REST:** `/api/v1/coupon/…`: draft/approve/revoke, festival opt-in
- **gRPC exposed:** `Coupon.ValidateCoupon` @9090 ¹ *(documented drift: §7 omits coupon's gRPC; §10 + diagrams + the connectivity matrix assign 9090 — **9090 is authoritative**)*
- **gRPC called:** none

## Events & queues

- **Emits (Kafka):** `dokandar.coupon.*`
- **Consumes (Kafka):** none
- **RabbitMQ / NATS:** none

## Operational notes

- **Idempotency / locks:** Redlock `coupon:redeem:lock:{coupon}:{user}` serializes concurrent redemptions; the `(coupon_id, order_id)` UNIQUE constraint is the durable guarantee.
- **Resilience:** callers (cart) fail-open on a coupon outage; Redis down → recompute from Postgres, do NOT fail readiness.
- **Security:** four-eyes approval enforced (approver ≠ drafter, audited); constant-time `INTERNAL_SERVICE_TOKEN`.

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
