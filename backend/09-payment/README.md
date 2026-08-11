# `09-payment` — Payments & Payouts

> **Status — specified, NOT yet implemented.** This folder is a **scaffold**: the service code
> (`Dockerfile`, `env/`, `test.sh`, application source) does **not** exist yet. The authoritative spec is
> [`../README.md`](../README.md) (the catalog) + [`../../README.md`](../../README.md) §6/§7/§10 +
> [`../../architecture.md`](../../architecture.md) §9. **On any conflict, the README wins — re-verify.**

## Identity

| Field | Value |
| --- | --- |
| Service | `09-payment` |
| Domain | Transaction & Orders |
| Language · framework | Elixir 1.20 · Phoenix 1.8 |
| Primary datastore(s) | PostgreSQL 18 (+ Redis DB8) |
| `SERVICE_PORT` (in-container) | 4000 (Phoenix) |
| gRPC port | — (REST-only) |
| External ports | REST `10009` · gRPC — |
| **`/ready` hard-gate** | **PostgreSQL** (Redis/Kafka/RabbitMQ not gating) |

## Bounded context

The money-movement lifecycle: payment intents, provider settlements, refunds, commission deduction, the **COD ledger** (~70% of volume), and shopkeeper payouts across bKash/Nagad/Rocket/SSLCommerz/Stripe. Each intent is an isolated BEAM process. Sole authority that declares money **settled**.

## Data ownership

PostgreSQL `dokandar_payment_<env>` (sole writer): `payment_intents` (idempotent by `order_id`), `payments`, `payment_webhooks` UNIQUE `(provider, event_id)` (replay fence), `payouts`, `cod_ledger`, `commission_rates`, `outbox`. Intent transitions run `FOR UPDATE`.

## Synchronous API

- **REST:** `/api/v1/payment/…`: intent CRUD, refunds, payouts, `POST /webhooks/{provider}`. **No gRPC server** — `13-order` creates the intent via an internal **REST** call with constant-time `INTERNAL_SERVICE_TOKEN` *(drift §22: §10-order says "all gRPC"; resolve to REST)*
- **gRPC exposed:** **none** (REST-only on 4000)
- **gRPC called:** none on Kafka — emit-only

## Events & queues

- **Emits (Kafka):** `dokandar.payment.*` (incl. `payment.settled`), `dokandar.refund.processed`
- **Consumes (Kafka):** **no Kafka** (driven by the sync intent call + provider webhooks)
- **RabbitMQ / NATS:** RabbitMQ → durable `payout.execute` worker (single-consumer, bound DLQ)

## Operational notes

- **Idempotency:** `order_id`-keyed intent uniqueness prevents double-charge; `UNIQUE (provider, event_id)` makes webhooks effectively-once.
- **Resilience:** circuit breakers per provider; on MFS outage **COD intents proceed**; payout failures → RabbitMQ DLQ. Effectively-once, not exactly-once.
- **Security:** every webhook **HMAC-SHA256**-verified before any state change; append-only `cod_ledger`; **PCI** — PANs never stored.

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
