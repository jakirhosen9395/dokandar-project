# `10-wallet` — Double-Entry Ledger

> **Status — implemented (Go 1.24 / Fiber v3 + GORM + gRPC + Elastic APM).** Full application source is
> present (`cmd/wallet`, `internal/…`), plus `Dockerfile`, `env/init-env.sh`, embedded migrations, the
> `proto/wallet.proto` gRPC contract, and `smoke_test/test.sh`. The authoritative spec is
> [`../README.md`](../README.md) (the catalog) + [`../../README.md`](../../README.md) §6/§7/§10 +
> [`../../architecture.md`](../../architecture.md) §9. **On any conflict, the README wins — re-verify.**
>
> Build/run drift vs spec: builder + `go.mod` pin Go **1.24** (matches the in-repo Go exemplar
> `02-profile`; spec says 1.26 — bump both together to go true-spec). gRPC runs in-container on
> **`GRPC_PORT=8001`** (mapped to external `20010`), mirroring the built Go services, not the spec's
> in-container `50051`. `go.sum` is generated at image build (`go mod download` + `go mod tidy`), since
> no local Go toolchain was available to commit it.

## Identity

| Field | Value |
| --- | --- |
| Service | `10-wallet` |
| Domain | Transaction & Orders |
| Language · framework | Go 1.26 · Fiber v3 + GORM |
| Primary datastore(s) | PostgreSQL 18 (+ Redis DB4) |
| `SERVICE_PORT` (in-container) | 8080 |
| gRPC port | 50051 |
| External ports | REST `10010` · gRPC `20010` |
| **`/ready` hard-gate** | **PostgreSQL** (Redis not gated — SERIALIZABLE preserves correctness) |

## Bounded context

The customer-wallet **double-entry ledger**: every movement is one immutable debit-XOR-credit row, balances derived + version-guarded, a cashback engine grants loyalty off order events, and MFS top-ups bridge into wallet credit under the regulatory **50,000 BDT** cap. Two write paths: sync `DebitWallet` on checkout, async cashback grant.

## Data ownership

PostgreSQL `dokandar_wallet_<env>` (sole writer): `wallet_accounts`; `wallet_entries` with **CHECK (debit XOR credit)** + **UNIQUE `idempotency_key`**; `wallet_balances` with optimistic `version` + CHECK (≥0 and ≤50000); `cashback_rules`, `cashback_grants`, `outbox`. Money paths run **`SERIALIZABLE`**.

## Synchronous API

- **REST:** `/api/v1/wallet/…`: balance, ledger entries, top-up
- **gRPC exposed:** `Wallet.GetBalance|DebitWallet|CreditWallet` @50051 (debit/credit = the saga's redemption + compensation)
- **gRPC called:** none

## Events & queues

- **Emits (Kafka):** `dokandar.wallet.credited|debited|cashback_granted`
- **Consumes (Kafka):** `dokandar.order.placed` (drive cashback)
- **RabbitMQ / NATS:** none

## Operational notes

- **Idempotency / locks:** Redlock `wallet:lock:{user}` serializes per-user money paths so SERIALIZABLE rarely aborts; **UNIQUE `idempotency_key`** makes a retried `DebitWallet` a no-op; cashback keyed on source `order_id` → exactly one grant.
- **Resilience:** a failed debit returns a clean error so the saga compensates (distinct idempotency_key → no double-refund); bounded retry-with-backoff on 40001.
- **Security:** the 50,000 BDT cap + double-entry invariant give a tamper-evident, auditable ledger; constant-time `INTERNAL_SERVICE_TOKEN`.

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
