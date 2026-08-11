# Coding Standards (generated services)

Generated services inherit the fleet conventions; the template enforces them structurally.

## Cross-cutting (all runtimes)
- **Hexagonal**: `domain ← application ← adapters`; the domain imports nothing outward.
- **Money** = `int64` poisha (never float/decimal/string); **time** = `int64` ms UTC; **IDs** typed via the SDK.
- **APIs**: external REST `/v1` with `{success,data,error,meta}`; RFC-7807 `problem+json`; cursor pagination; `Idempotency-Key` on unsafe/money/custody writes.
- **Events**: cross-context via Kafka only (R6); RabbitMQ intra-context only; payloads carry IDs, never PII.
- **Effectively-once**: transactional outbox + consumer inbox + DLQ.
- **Errors**: typed exceptions → `dokandar.<context>.<category>.<reason>` (SDK builder); never leak internals.
- **Config**: 12-factor; secrets via the platform secret manager; never committed.
- **Tests**: unit + integration (testcontainers); money/custody paths ≥ 90% coverage; Tier-0 mutation ≥ 80%.

## Per-runtime
- **Go**: `gofmt`/`go vet`; stdlib-first; errors wrapped with `%w`.
- **Java/Spring**: Spring Boot conventions; constructor injection; Bean Validation at the edge.
- **C#/.NET**: nullable enabled; records for DTOs; ASP.NET Core minimal API + health checks.
- **Python**: PEP 8 + type hints; FastAPI; pydantic validation at the boundary.
- **Node/TS**: strict TypeScript, ESM; Fastify; zod/schema validation at the edge.

## Forbidden
No TODO/FIXME/placeholder/mock/fake/pseudo-code in committed code (CI-gated). No invented business rules (P2). No cross-context DB access (R6).
