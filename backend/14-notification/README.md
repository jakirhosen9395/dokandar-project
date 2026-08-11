# `14-notification` — Multi-Channel Fan-Out

> **Status — specified, NOT yet implemented.** This folder is a **scaffold**: the service code
> (`Dockerfile`, `env/`, `test.sh`, application source) does **not** exist yet. The authoritative spec is
> [`../README.md`](../README.md) (the catalog) + [`../../README.md`](../../README.md) §6/§7/§10 +
> [`../../architecture.md`](../../architecture.md) §9. **On any conflict, the README wins — re-verify.**

## Identity

| Field | Value |
| --- | --- |
| Service | `14-notification` |
| Domain | Fulfilment, Engagement, Media & Edge |
| Language · framework | Node.js 24 LTS · Fastify 5 |
| Primary datastore(s) | MongoDB 8.3 (+ Redis DB10, NATS JetStream) |
| `SERVICE_PORT` (in-container) | 3000 |
| gRPC port | — |
| External ports | REST `10014` · gRPC — |
| **`/ready` hard-gate** | **MongoDB only** (Redis degradable, not gating; RabbitMQ/Kafka diagnostic) |

## Bounded context

The event-to-user fan-out fabric: ingests Kafka facts, materializes a per-user **bilingual inbox**, and dispatches per-channel — **SMS** via SSL Wireless (primary, registered sender-ID), **WhatsApp** Business Cloud, **FCM push**, **email** via Amazon SES — plus a real-time inbox over **WebSocket** with cross-pod fan-out. Terminal consumer (no outbox).

## Data ownership

MongoDB: `notifications` (bilingual `title`/`body`), `notification_preferences`, `notification_dispatch_log` (90-day TTL index). No SQL, **no outbox**. Opaque `user_id`.

## Synchronous API

- **REST:** `/api/v1/notification/…`: inbox read / mark-read, preference CRUD, `GET /ws/inbox` (WebSocket upgrade)
- **gRPC exposed:** none
- **gRPC called:** none on the hot path (enrichment uses Kafka payloads directly)

## Events & queues

- **Emits (Kafka):** **nothing**
- **Consumes (Kafka):** `dokandar.user.created`, `dokandar.order.placed`, `dokandar.payment.*`, `dokandar.kyc.*`, `dokandar.wallet.cashback_granted`
- **RabbitMQ / NATS:** RabbitMQ → `notifications.{email,sms,push,whatsapp_deeplink}` (+ drains `notifications.otp.send` from `01-auth`), each with a DLQ. **NATS JetStream** carries WebSocket fan-out subjects

## Operational notes

- **Idempotency:** Redis DB10 `notif:dedup:<topic>:<key>` (24-h TTL) absorbs Kafka redelivery; `ws:user:<id>` maps user→pod; cross-pod Redis pub/sub broadcasts inbox events.
- **Resilience:** failing provider → retry-with-backoff → DLQ for SRE triage; KEDA autoscales on RabbitMQ queue depth per channel.
- **Security:** carries PII (phone, order details, KYC, OTP); **OTP bodies never logged**; constant-time `crypto.timingSafeEqual`.

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
