# `13-order` — Checkout Saga

> **Status — specified, NOT yet implemented.** This folder is a **scaffold**: the service code
> (`Dockerfile`, `env/`, `test.sh`, application source) does **not** exist yet. The authoritative spec is
> [`../README.md`](../README.md) (the catalog) + [`../../README.md`](../../README.md) §6/§7/§10 +
> [`../../architecture.md`](../../architecture.md) §9. **On any conflict, the README wins — re-verify.**

## Identity

| Field | Value |
| --- | --- |
| Service | `13-order` |
| Domain | Transaction & Orders |
| Language · framework | Java 25 LTS · Spring Boot 4.0 + Temporal |
| Primary datastore(s) | PostgreSQL 18 (+ Redis DB7, Temporal) |
| `SERVICE_PORT` (in-container) | 8080 |
| gRPC port | 9090 |
| External ports | REST `10013` · gRPC `20013` |
| **`/ready` hard-gate** | **PostgreSQL** (Redis locks + Kafka + Temporal not gated — Temporal reported in `/health`) |

## Bounded context

The checkout **saga orchestrator**: accepts the cart's immutable checkout-package and drives the order state machine (`placed → confirmed → packed → shipped/ready_for_pickup → delivered/picked_up → completed`, with `cancelled`/`returned`) as a **Temporal workflow** with compensation. Writes one **sub-order per shop** so multi-vendor baskets fulfil + settle independently. System of record for order state.

## Data ownership

PostgreSQL `dokandar_order_<env>` (sole writer): `orders` UNIQUE `idempotency_key` (the `Idempotency-Key` fence on `POST /orders`), `sub_orders`, `order_lines`, `order_status_history` (append-only audit), `outbox`.

## Synchronous API

- **REST:** `/api/v1/order/…`: `POST /orders` (Idempotency-Key required), reads, sub-order transitions
- **gRPC exposed:** `Order.HasPurchased` @9090
- **gRPC called:** at place time: `Catalog.ReserveStock`, `Coupon.ValidateCoupon`, `Wallet.DebitWallet`, + internal REST → `09-payment`. Compensations: `Catalog.ReleaseStock`, coupon reversal, `Wallet.CreditWallet`

## Events & queues

- **Emits (Kafka):** `dokandar.order.placed|status_changed|confirmed|delivered|refunded|cancelled`
- **Consumes (Kafka):** `dokandar.payment.settled` (advance placed→confirmed)
- **RabbitMQ / NATS:** none

## Operational notes

- **Idempotency / locks:** `orders.idempotency_key` makes a retried `POST /orders` return the existing order; Redis DB7 arbitration locks on concurrent sub-order transitions; Temporal dedup makes activities at-least-once-safe.
- **Resilience:** saga compensation is first-class — any activity failure triggers the inverse activities; circuit breakers + deadlines on every client. Effectively-once.
- **Security:** `POST /orders` requires the customer Bearer; east-west uses constant-time `INTERNAL_SERVICE_TOKEN`; immutable `order_status_history` audit.

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
