# `15-api-gateway` — Edge Ingress

> **Status — specified, NOT yet implemented.** This folder is a **scaffold**: the service code
> (`Dockerfile`, `env/`, `test.sh`, application source) does **not** exist yet. The authoritative spec is
> [`../README.md`](../README.md) (the catalog) + [`../../README.md`](../../README.md) §6/§7/§10 +
> [`../../architecture.md`](../../architecture.md) §9. **On any conflict, the README wins — re-verify.**

## Identity

| Field | Value |
| --- | --- |
| Service | `15-api-gateway` |
| Domain | Fulfilment, Engagement, Media & Edge |
| Language · framework | Go 1.26 · Echo v5 (Envoy/Kong at scale) |
| Primary datastore(s) | Redis 8 (DB13) — stateless otherwise |
| `SERVICE_PORT` (in-container) | 8080 |
| gRPC port | — |
| External ports | REST `10015 → 443 public` · gRPC — |
| **`/ready` hard-gate** | **none** (JWKS verify runs off the in-process cache; routing is stateless — serves with Redis down) |

## Bounded context

The **sole** client entry point: after Cloudflare, it verifies JWTs, gates auth per route, rate-limits, applies CORS + security headers, and reverse-proxies east-west over **Istio (mTLS)**. BFF aggregation stitches multi-service responses. The platform's **security choke point and contract-enforcement edge**.

## Data ownership

**Stateless** — no business datastore. Redis DB13 only, for the token-bucket rate-limiter. No DB/outbox/events.

## Synchronous API

- **REST:** **verbatim path forwarding** (`/api/v1/<svc>/…`), JWKS verify (5-min cache of `01-auth`'s `/jwks`; `algorithms:['RS256']`), per-route auth gating, Redis token-bucket rate-limit, CORS + security headers, BFF fan-out; centralizes the edge bare-404 / pretty-JSON / `x-request-id`
- **gRPC exposed:** **none** — east-west reverse-proxy rides Istio
- **gRPC called:** none (proxies, doesn't consume gRPC directly)

## Events & queues

- **Emits (Kafka):** **nothing** — never touches Kafka/RabbitMQ/NATS
- **Consumes (Kafka):** **nothing**
- **RabbitMQ / NATS:** none

## Operational notes

- **Idempotency / locks:** Redis DB13 token bucket keyed by principal/route; JWKS cached in-process; idempotency delegated to downstream money/stock owners.
- **Resilience:** per-upstream circuit breakers + deadlines; a JWKS-fetch failure serves from the cached key set; rate-limiter fails open/closed per route policy.
- **Security:** the single front door — JWT verification, route authorization, header hygiene (HSTS/CSP/no-sniff), bot/rate defenses; holds no PII at rest.

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
