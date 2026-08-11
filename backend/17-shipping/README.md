# `17-shipping` — Fulfilment & Routing

> **Status — specified, NOT yet implemented.** This folder is a **scaffold**: the service code
> (`Dockerfile`, `env/`, `test.sh`, application source) does **not** exist yet. The authoritative spec is
> [`../README.md`](../README.md) (the catalog) + [`../../README.md`](../../README.md) §6/§7/§10 +
> [`../../architecture.md`](../../architecture.md) §9. **On any conflict, the README wins — re-verify.**

## Identity

| Field | Value |
| --- | --- |
| Service | `17-shipping` |
| Domain | Fulfilment, Engagement, Media & Edge |
| Language · framework | Ruby 4.0 · Rails 8.1 |
| Primary datastore(s) | PostgreSQL 18 + Neo4j 2026.x |
| `SERVICE_PORT` (in-container) | 3000 (Puma) |
| gRPC port | 50051 |
| External ports | REST `10017` · gRPC `20017` |
| **`/ready` hard-gate** | **PostgreSQL** (Neo4j is a routing optimizer, not gating — quotes degrade without it) |

## Bounded context

Last-mile orchestration: per-sub-order **courier selection** by cost/SLA/address-tier across **Pathao, Paperfly, RedX, Sundarban, eCourier**, plus the platform's own **rural agent network** for upazila delivery. Books consignments, ingests status webhooks, runs **Neo4j** vehicle-routing over the upazila road graph. Its `shipment.failed_delivery` event is the **COD-refusal signal** for `18-risk-trust`.

## Data ownership

PostgreSQL `dokandar_shipping_<env>`: `shipments`, `shipment_events`, `couriers`, `courier_pricing_rules`, `rural_agents`, `delivery_zones`, `outbox`. Neo4j `dokandar_road_graph`: `Upazila`/`Union`/`Hub` nodes, `:ROAD_TO {distance_km, time_min}` edges (indexed for shortest-path/VRP).

## Synchronous API

- **REST:** `/api/v1/shipping/…`: shipment create/track, courier status webhooks, admin agent-routing
- **gRPC exposed:** `Shipping.QuoteDelivery` @50051 (called by `13-order` at checkout) *(drift §22: §9 names an older `ComputeDeliveryRoute`; canonical is **`Shipping.QuoteDelivery`**)*
- **gRPC called:** none on the hot path

## Events & queues

- **Emits (Kafka):** `dokandar.shipment.*` (incl. `shipment.delivered`, `shipment.failed_delivery`)
- **Consumes (Kafka):** `dokandar.order.confirmed` (book), `dokandar.order.cancelled` (cancel/recall)
- **RabbitMQ / NATS:** none

## Operational notes

- **Idempotency:** booking Idempotency-Key enforced by a UNIQUE constraint → a redelivered `order.confirmed` or retried webhook never double-books.
- **Resilience:** **courier-API outage → failover** to the next-best courier (or rural-agent fallback); Neo4j unavailable → straight-line/zone-table distance estimates rather than failing quotes.
- **Security:** delivery addresses + recipient phone (PII); courier webhooks signature-verified; constant-time `Rack::Utils.secure_compare`.

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
