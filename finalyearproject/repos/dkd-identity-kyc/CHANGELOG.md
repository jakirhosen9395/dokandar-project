# Changelog
All notable changes to **dkd-identity-kyc** are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning: [SemVer](https://semver.org/).

## [Unreleased]

## [0.4.0] — 2026-07-01
### Changed
- **Replaced Scalar with Swagger UI (Swashbuckle.AspNetCore).** Interactive UI at **`/docs`**
  (`RoutePrefix="docs"`), OpenAPI JSON at **`/swagger/v1/swagger.json`**. Single OpenAPI generator
  (removed `Scalar.AspNetCore` and `Microsoft.AspNetCore.OpenApi`).
- Every REST endpoint now carries full OpenAPI metadata (`WithName/Summary/Description/Tags`,
  `Accepts/Produces/ProducesProblem`); all 8 party operations + every request/response model appear
  in Swagger. `Idempotency-Key` and `X-Dkd-Roles` are surfaced as fillable headers for "Try it out".
### Fixed
- `SecurityHeadersMiddleware` CSP relaxed for `/docs` and `/swagger` only (Swagger UI needs inline
  script/style); API/data responses keep the strict `default-src 'none'`.
- Unique Swagger schema ids (full type name) to avoid a `ProblemDetails` schemaId collision.

## [0.3.0] — 2026-07-01
### Added
- **Interactive API documentation UI (Scalar)** at `/scalar/v1` (`/scalar` redirects to it), rendering
  the built-in OpenAPI document. Package `Scalar.AspNetCore`. (Swagger UI intentionally not used —
  Scalar consumes .NET's built-in `Microsoft.AspNetCore.OpenApi` without a second generator.)

## [0.2.0] — 2026-07-01
### Added
- **Idempotency-Key** enforcement on unsafe writes (mandatory per EF §7): a per-key store replays the
  first successful response on retry (migration `0002_idempotency`, `IdempotencyMiddleware`).
- **Outbox park-and-freeze:** poison rows stop retrying after 10 attempts and are logged (never
  silently dropped), kept for manual replay.
- **Consumer-driven contract/fitness tests:** event payloads carry no PII (C1/R6), topic names conform
  to the SDK constants, KYCSubmitted is RabbitMQ-only.
- **CI integration tests** against a real `postgres` service (DB write/read + idempotency); Testcontainers
  dependency removed.
- **OpenAPI** document at `/openapi/v1.json`.
### Changed
- REST unsafe writes now require the `Idempotency-Key` header (400 `idempotency_key_required` if absent).

## [0.1.0] — 2026-07-01
### Added
- **Identity, Party & KYC service (MVP).** Party aggregate (root ID = DID), value objects (Phone E.164
  +880, NidHash SHA-256), KYC tier state machine (UNVERIFIED→BASIC→FULL→BUSINESS), suspend/reactivate.
- CQRS command handlers: RegisterParty, SubmitKYC, ApproveKYC, UpgradeKYCTier, RejectKYC, SuspendParty,
  ReactivateParty; Party read model + query.
- REST `/v1/parties*` (envelope + RFC-7807 + role-gated commands) and the `identity-party-ohs` gRPC
  service (ResolveParty, GetKycTier) — the platform PII resolver (R7).
- The 6 frozen `identity.party.*` Kafka events + `KYCSubmitted.v1` (RabbitMQ), published via a
  transactional outbox + background dispatcher; Npgsql persistence; SQL migrations (0001_init).
- Domain error taxonomy `dokandar.identity.*`; hexagonal layout consuming the vendored `Dkd.Platform` SDK.
- CI: governance + C# build & unit tests. Docker image + Compose deployment (Kubernetes-ready).
- Verified end-to-end against the shared S2 infra (Postgres/Kafka/RabbitMQ): 23/23 unit tests, REST,
  gRPC, events, outbox. See `docs/IMPLEMENTATION.md`.

Trace: R6, R7, ADR-008, ADR-011; DM "Context #1 — Identity/KYC"; dkd-contracts-spine@v1.0.0

## [0.0.0] — 2026-06-29
### Added
- Stage 0.1 repository skeleton and governance baseline (README, architecture notes, CODEOWNERS,
  issue/MR templates, shared governance CI, Conventional-Commits + SemVer scaffolding). No business logic.

Trace: ADR-024, EF§2.3
