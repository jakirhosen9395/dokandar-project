# identity-svc — Implementation Notes

**Context #1 — Identity, Party & KYC.** Runtime C#/.NET 10. The master-data backbone: DID issuer,
Party read model + sole PII resolver, KYC tiers. Trace: R6, R7, ADR-008, ADR-011; DM "Context #1 —
Identity/KYC"; SA identity-svc; frozen contracts `dkd-contracts-spine@v1.0.0`.

## Architecture (hexagonal, ports & adapters)

```
src/Domain/        Party aggregate, value objects (Phone, NidHash), KycTier/PartyStatus, domain events
src/Application/   PartyService (CQRS command handlers + queries), ports (IIdentityUnitOfWork, IClock, IOtpVerifier)
src/Adapters/      Npgsql persistence + transactional outbox, Kafka/RabbitMQ publishers, OutboxDispatcher, SqlMigrator
src/Http/          REST /v1 endpoints + blueprint middleware
src/Grpc/          identity-party-ohs gRPC service
proto/             identity_party_ohs.proto
migrations/        0001_init.sql (party, outbox, schema_migrations)
sdk/Dkd.Platform/  vendored platform SDK (pinned v1.3.0) — see Known limitations
```

Dependency rule: `domain ← application ← adapters`. The domain imports only `Dkd.Platform` primitives
(DID, error taxonomy). No business logic in `Http`/`Grpc` — they translate transport to commands.

## Implementation decisions

- **DID minting:** `did:dokandar:{uuid7}` via .NET `Guid.CreateVersion7()`; immutable (SDK `DID` type).
- **PII confinement (C1/R6):** raw NID is hashed (`SHA-256`) on submit and never stored; phone is stored
  only here and **masked** in the REST read model. Kafka payloads carry IDs only. The gRPC OHS
  (`ResolveParty`) is the only surface that returns raw phone — it is the platform PII resolver (R7).
- **Transactional outbox:** each command writes aggregate state + emitted events to the `outbox` table
  in one Postgres transaction; a background `OutboxDispatcher` publishes to Kafka/RabbitMQ and marks
  rows sent (at-least-once; consumers dedup via inbox on `event_id`).
- **Events serialize to exactly the DM payload:** `IDomainEvent` envelope members are `[JsonIgnore]`d.
- **KYC tier naming:** DM enum `UNVERIFIED|BASIC|FULL|BUSINESS` is authoritative for the aggregate;
  maps 1:1 to the BA `V0..V3` via FR-IDN-310 (V0=UNVERIFIED … V3=BUSINESS).
- **Authorization (PDP seam):** command role checks (`SYSTEM` for KYC approve/upgrade/reject,
  `ENFORCEMENT` for suspend) are enforced in the domain; caller roles are read at the edge from the
  verified JWT — in the dev substrate via `X-Dkd-Roles`/`X-Dkd-Caller-Did` headers (gateway-injected in
  production). The full RBAC/ABAC matrix is Phase 2.
- **Ports:** REST on **8080 (HTTP/1.1)**, gRPC on **8081 (HTTP/2 cleartext)** — Kestrel cannot serve
  h2c on an Http1AndHttp2 port without TLS/ALPN — metrics on **9090**.
- **No-DB boot:** when `DKD_DB_DSN` is empty the service boots health-only (Noop infra) so blueprint
  health tests run without a database.

## APIs

REST `/v1` (envelope `{success,data,error,meta}`, RFC-7807 errors):
| Method | Path | Purpose | Role |
|---|---|---|---|
| POST | `/v1/parties` | RegisterParty (OTP-verified, phone unique) → DID | — |
| GET  | `/v1/parties/{did}` | Party read model (masked phone) | — |
| POST | `/v1/parties/{did}/kyc` | SubmitKYC (→ RabbitMQ) | — |
| POST | `/v1/parties/{did}/kyc/approve` | ApproveKYC (→ BASIC) | SYSTEM |
| POST | `/v1/parties/{did}/kyc/upgrade` | UpgradeKYCTier (FULL/BUSINESS) | SYSTEM |
| POST | `/v1/parties/{did}/kyc/reject` | RejectKYC | SYSTEM |
| POST | `/v1/parties/{did}/suspend` | SuspendParty | ENFORCEMENT |
| POST | `/v1/parties/{did}/reactivate` | ReactivateParty | — |

gRPC `dokandar.identity.ohs.v1.IdentityPartyOhs` (port 8081): `ResolveParty`, `GetKycTier`.

**API docs:** **Swagger UI at `/docs`** (Swashbuckle) with the OpenAPI JSON at
`/swagger/v1/swagger.json`. All 8 party operations + health appear with full metadata and schemas;
`Idempotency-Key` and `X-Dkd-Roles` are fillable headers for "Try it out". CSP is relaxed only on the
`/docs`/`/swagger` paths (Swagger UI needs inline script/style); all API responses keep `default-src 'none'`.

## Events (frozen `messaging.yaml`, key = DID)

Kafka (Published Language): `identity.party.PartyRegistered.v1`, `KYCApproved.v1`, `KYCTierChanged.v1`,
`KYCRejected.v1`, `PartySuspended.v1`, `PartyReactivated.v1`.
RabbitMQ (intra-context, NOT PL): `KYCSubmitted.v1` → `identity.kyc-verification`.

## Configuration (env only → k8s ConfigMap/Secret)

| Var | Purpose |
|---|---|
| `DKD_SERVICE_NAME` / `DKD_CONTEXT` / `DKD_ENV` | identity |
| `DKD_HTTP_PORT` (8080) / `DKD_GRPC_PORT` (8081) | REST / gRPC ports |
| `DKD_DB_DSN` | Npgsql conn string to `dkd_identity` (secret) |
| `DKD_KAFKA_BROKERS` | Kafka bootstrap (`<s2-ip>:9092`) |
| `DKD_RABBITMQ_URL` | `amqp://user:pass@<s2-ip>:5672/` (secret) |
| `DKD_DEV_OTP` | dev OTP token (default `000000`) — Phase 2 replaces with real OTP |
| `DKD_JWT_ISSUER` | JWT issuer (PDP integration) |

## Deployment (Docker-first, k8s-ready)

Image `identity-svc:local` (multi-stage, non-root uid 1654). Deploy on S3 via
`deploy/compose.deploy.yml` with `.env.deploy` (secrets injected from the S2 secret set, gitignored).
Connects to the shared infra on S2 over the private network. Helm chart + k8s manifests under `deploy/`
carry the same image/health/metrics — migration to k8s changes only the runtime, not the artifact.

## Verification evidence (against real S2 infra)

- Build: 0 warnings / 0 errors (net10.0). Unit tests: **23/23** (17 domain + 6 health).
- Migrations: `0001_init` applied to `dkd_identity`.
- REST: 10/10 e2e (register→get→submit→approve[role-gated]→upgrade→suspend→reactivate; 400/403/409 negatives).
- gRPC: `ResolveParty` (returns PII phone) + `GetKycTier` + unknown→found:false.
- Kafka: all 5 event types observed on S2 topics for a test DID.
- RabbitMQ: `KYCSubmitted` delivered to `identity.kyc-verification`.
- DB/outbox: `outbox` 6 rows, 6 sent, 0 unsent; atomic state+event.

## Idempotency (v0.2.0)

Unsafe writes (`POST /v1/parties*`) require an `Idempotency-Key` header (400
`dokandar.identity.validation.idempotency_key_required` if absent). `IdempotencyMiddleware` records the
first successful response per key (`idempotency_keys` table) and replays it on retry
(`Idempotency-Replayed: true`), so clients can retry safely without creating duplicates.

## Outbox reliability

At-least-once via the outbox + dispatcher. A row that fails to publish is retried; after 10 attempts it
is **parked** (frozen, logged at Error, not polled again, never dropped) for manual replay.

## Tests

- Unit (40): domain aggregate (17), health pipeline (6), consumer-driven contract/fitness (17 —
  no-PII payloads, topic conformance, RabbitMQ-only KYCSubmitted, error taxonomy).
- Integration (3): boots the app against a real PostgreSQL (CI `postgres` service / `DKD_TEST_DB_DSN`) —
  DB write/read + idempotency replay + mandatory-key rejection.

## Known limitations / deferred (Phase 2 — genuinely cross-service or contract-NEEDS-INFO)

- **Vendored SDK:** `sdk/Dkd.Platform` is a pinned copy of `dkd-platform-libs@v1.3.0` because the SDK is
  not yet published to a NuGet feed. Replace with a `PackageReference` once publishing is wired.
- **OTP delivery:** `DevOtpVerifier` validates a fixed dev token; real SMS/IVR OTP issuance depends on
  the platform notification service (context 13) — Phase 2 (FR-IDN-010+).
- **PDP:** full RBAC/ABAC policy matrix, sessions/devices/JWT (JWKS) verification, PKI/custodial signing —
  Phase 2 (depends on the platform auth surface).
- **kyc-adapter-svc** (EC-NID/NBR ACL), KYC document storage, USSD/SMS/IVR channel parity (R8) — separate
  units, deferred.
- **OpenAPI** exposes the base document; per-endpoint business schemas are Phase-2 NEEDS-INFO per api-registry.
