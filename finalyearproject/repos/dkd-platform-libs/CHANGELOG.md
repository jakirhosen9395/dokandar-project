## [1.8.0] — 2026-07-01 · API Documentation Standard helper in the Java SDK
### Added
- **`DkdApiDocs`** Spring auto-configuration + springdoc-openapi-starter-webmvc-ui (transitive): supplies the OpenAPI document (doc v1, title=spring.application.name) + Bearer/JWT scheme; springdoc serves Swagger UI /docs + OpenAPI JSON /swagger/v1/swagger.json (paths in application.yml). Services need no Swagger code. Verified: generated Spring Boot service builds (Maven) + serves /docs (302->200 UI) + /swagger/v1/swagger.json (200, OpenAPI 3.0.1, v1, Bearer).
### Note
- All five SDK helpers now implemented/verified: C# v1.4.0, Python v1.5.0, Go v1.6.0, Node v1.7.0, Java (this).

## [1.7.0] — 2026-07-01 · API Documentation Standard helper in the TypeScript SDK
### Added
- **@dokandar/platform-sdk `apidocs`** (Node/stdlib http): handleDocs(req,res,title) serves Swagger UI /docs + OpenAPI JSON /swagger/v1/swagger.json; isDocsPath/DOCS_CSP for the CSP carve-out. Verified: generated Node service builds + serves /docs 200 + /swagger.json 200 (OpenAPI 3.0.3, v1, Bearer).

## [1.6.0] — 2026-07-01 · API Documentation Standard helper in the Go SDK
### Added
- **`.../sdk/go/apidocs`** (stdlib only): `Register(mux, title)` serves Swagger UI at `/docs` and the
  OpenAPI JSON at `/swagger/v1/swagger.json`; `IsDocsPath` + `DocsCSP` for the CSP carve-out. Verified:
  generated Go service builds + serves /docs (200) + /swagger.json (200, OpenAPI 3.0.3, v1, Bearer).

## [1.5.0] — 2026-07-01 · API Documentation Standard helper in the Python SDK
### Added
- **`dkd_platform.apidocs`** (Python/FastAPI): `platform_docs_kwargs(title)` + `configure_platform_docs(app)`
  centralize the platform Swagger behavior — Swagger UI at `/docs`, OpenAPI JSON at
  `/swagger/v1/swagger.json`, OpenAPI doc `v1`, Bearer/JWT security scheme. FastAPI import is lazy so the
  SDK stays importable without FastAPI. Verified: a generated Python service serves /docs (200) and
  /swagger/v1/swagger.json (200, OpenAPI 3.1, Bearer present).
### Note
- C# (v1.4.0) + Python (this) SDK helpers are implemented/verified. Java/Go/Node helpers pending.

## [1.4.0] — 2026-07-01 · API Documentation Standard helper in the C# SDK
### Added
- **`Dkd.Platform.ApiDocs`** — the platform API-documentation helper: `AddDkdApiDocs(title)` +
  `UseDkdApiDocs()` wire OpenAPI + Swagger UI identically for every service (OpenAPI doc `v1`, JSON at
  `/swagger/v1/swagger.json`, UI at `/docs`, Bearer/JWT security scheme, unique schema ids). Services
  enable compliant docs with one call — no per-service Swagger configuration. The native tool
  (Swashbuckle) is an implementation detail behind the helper.
- The C# SDK now carries `FrameworkReference Microsoft.AspNetCore.App` + `Swashbuckle.AspNetCore`
  (transitively available to consuming services). Emitted via the generator (drift-clean); SDK tests 5/5.
### Note
- Runtime-agnostic standard: each runtime SDK must expose the equivalent helper using native tooling
  (service-template `docs/api-documentation-standard.md`). C# is the reference; others pending.

## [1.3.0] — 2026-06-30 · OpenAPI generator + C# namespace fix
### Added
- **OpenAPI Generator** (`openapi_emit`) — sixth emitter on the same IR (no duplicated logic). Emits
  a **valid OpenAPI 3.1** document (`sdk/openapi/dkd-platform.openapi.json`) from the contracts: the
  universal operational endpoints + the mandated cross-cutting components (envelope, RFC-7807, cursor
  pagination, bearer-JWT, idempotency/correlation headers, int64 money/time) + the registered OHS
  operations. Per-endpoint business specs remain `x-dkd-deferred` (frozen contracts NEEDS-INFO; never
  fabricated). Covered by `tests/test_openapi.py` (7 tests) + `openapi:validate` CI + drift gate.
  See `docs/openapi-generation-and-deferral.md`.
### Fixed
- **C# SDK namespace** aligned to `Dkd.Platform` (was `Dokandar.Platform` while the assembly/package
  and every consumer used `Dkd.Platform`) — the generated C# service now compiles against the SDK.

# Changelog
All notable changes to **dkd-platform-libs** are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning: [SemVer](https://semver.org/).

## [1.2.0] — 2026-06-30  ·  toolchain refresh (latest 2026)
### Changed
- All SDK toolchains/dependencies bumped to latest 2026 stable: Go 1.25, .NET 10 (net10.0),
  Java 21 + JUnit 5.11.4 + Surefire 3.5.2, TypeScript 5.7 + @types/node 24, Python 3.13;
  CI images golang:1.25, maven:3.9-eclipse-temurin-21, dotnet/sdk:10.0, node:24, python:3.13-slim.
  Regenerated deterministically from the frozen contracts (unchanged).

## [1.1.0] — 2026-06-29  ·  Phase 3 (additive)
### Added
- **C# (.NET 8) SDK emitter** — the fifth SDK, generated from the same IR / contract model as the
  others (no duplicated generator logic); CI builds and tests it (`sdk:csharp`). Deterministic.
### Changed
- `contracts:compat` CI now asserts the consumed contracts are frozen at **v1.0.0** (decoupled from
  the platform-libs repo version, which is now 1.1.0).

## [1.0.0] — 2026-06-29  ·  Phase 2
### Added
- `dkdgen` — the single canonical SDK generator: contract parser + IR (`dkdgen.ir`), freeze-integrity
  verification, CLI (`generate`/`verify`), and one emitter per language.
- Pinned, SHA-256-verified snapshot of `dkd-contracts-spine@v1.0.0` under `contracts/` (consumed, never edited).
- Generated SDKs for **Java, Go, TypeScript, Python** with identical semantics: ids, money/time,
  topics+events, config, enums, errors taxonomy, DTO/envelope, schema-registry metadata, security, validation.
- Framework-only extension points for contract-deferred data (event payloads, JSON-Schemas, error-code
  catalog, OpenAPI/proto, permission matrix) — never fabricated.
- GitLab CI: governance · generator tests · contract-compatibility · generator-drift · per-language
  build/test · version validation. Deterministic regeneration via `scripts/generate.sh`.
- Documentation: README, architecture, generator/SDK/versioning/release/developer/migration guides.

Trace: R6, R7, ADR-008, ADR-010, ADR-016, ADR-021
