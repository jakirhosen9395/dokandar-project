# `06-cart` — Cart & Checkout Package

> **Status — specified, NOT yet implemented.** This folder is a **scaffold**: the service code
> (`Dockerfile`, `env/`, `test.sh`, application source) does **not** exist yet. The authoritative spec is
> [`../README.md`](../README.md) (the catalog) + [`../../README.md`](../../README.md) §6/§7/§10 +
> [`../../architecture.md`](../../architecture.md) §9. **On any conflict, the README wins — re-verify.**

## Identity

| Field | Value |
| --- | --- |
| Service | `06-cart` |
| Domain | Commerce Core |
| Language · framework | Node.js 24 LTS · NestJS 11 + Prisma 6 |
| Primary datastore(s) | MongoDB 8.3 + Redis 8 (DB5) |
| `SERVICE_PORT` (in-container) | 3000 |
| gRPC port | — (gRPC **client** only) |
| External ports | REST `10006` · gRPC — |
| **`/ready` hard-gate** | **MongoDB AND Redis** (Redis required for the guest-cart path + checkout lock); no Postgres |

## Bounded context

Authenticated + guest carts, wishlists, and the immutable **checkout-package quote** that `13-order` replays at place time. Guest carts live in Redis keyed by an HTTP-only cookie id (7-day TTL), merging on login. Bilingual line snapshots; festival discounts resolved at quote build via coupon.

## Data ownership

MongoDB (Prisma 6 — v7 dropped MongoDB): `carts`, `cart_items` (with `price_stale`), `wishlists`. Redis DB5: `guest:cart:<cookie>`, `cart:idem:<user>:<key>`, `cart:lock:<user>`. No Postgres.

## Synchronous API

- **REST:** `/api/v1/cart/…`: item CRUD, `POST /api/v1/cart/me/checkout-package`, guest-merge
- **gRPC exposed:** none
- **gRPC called:** **client** at quote build: `Catalog.CheckStock`, `Coupon.ValidateCoupon`, `Risk.ScoreCheckout`

## Events & queues

- **Emits (Kafka):** **nothing** (no outbox)
- **Consumes (Kafka):** `dokandar.product.changed` (flag `price_stale`), `dokandar.order.placed` (clear purchased lines)
- **RabbitMQ / NATS:** none

## Operational notes

- **Idempotency / locks:** `cart:lock:<user>` (`SET NX EX` Redlock) serializes concurrent checkout-package builds; `cart:idem:<user>:<key>` dedups the Idempotency-Key.
- **Resilience:** deadlines + circuit breakers on all three gRPC calls — `CheckStock` fail-closed, `ValidateCoupon` fail-open, `Risk.ScoreCheckout` fail-closed/hold for COD.
- **Security:** verify-only JWT (auth carts) / cookie-id-scoped (guest); opaque ids only.

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
