# Architecture notes — dkd-contracts-spine

> Target structure and binding rules. **No code yet** (Stage 0.1). Implementation lands in Stage 0.

## Hexagonal layout (target)

Dependency rule: **`domain ← application ← adapters`** — the domain imports nothing outward
(EF §13.1.2; CI architecture-fitness functions enforce this).

```
domain ← application ← adapters
```

## Rules this context must uphold

- Enforcement labels: **R6, ADR-016, ADR-017**.
- **R6** — all cross-context integration via the Kafka Published Language (or declared OHS gRPC);
  never touch another context's store. RabbitMQ is intra-context only.
- **Effectively-once** — transactional outbox + consumer inbox (dedup on `event_id`) + per-topic DLQ;
  money/custody/inventory poison messages are park-and-frozen, never dropped.
- **Types** — money `int64` poisha (float/decimal/string banned, lint-enforced); time `int64` ms UTC;
  IDs UUIDv7 with canonical prefixes; raw NID never stored (`SHA-256(rawNID)` only).
- **APIs** — external REST `/v1` (envelope `{success,data,error,meta}`, cursor pagination, RFC-7807
  `problem+json`, `Idempotency-Key` on unsafe/money/custody writes); internal gRPC OHS only.

## Canonical references (by ID — never restated here)

- Domain detail, aggregates, events, CustodyHash → `DOKANDAR-Domain-Model.md`.
- Service build/messaging/security → `DOKANDAR-Service-Architecture.md` (Ch.27 hardening for Tier-0).
- Topics/persistence → `dkd-contracts-spine/messaging.yaml`, `data-stores.yaml`.
- Engineering standards → `Engineering-Foundation.md`; design rules → `constitution-index/design-rules-R1-R8.md`.

Trace: R6, EF§13.1.2, DM type-conventions
