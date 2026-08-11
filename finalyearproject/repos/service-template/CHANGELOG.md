## [0.9.0] — 2026-07-01 · Java runtime joins the API Documentation Standard — PARITY ACHIEVED (all 5 runtimes)
### Added
- **Java scaffold inherits the SDK DkdApiDocs auto-config**: application.yml sets springdoc.swagger-ui.path=/docs + springdoc.api-docs.path=/swagger/v1/swagger.json; the OpenAPI doc (v1) + Bearer scheme come from the SDK (springdoc transitive). No per-service Swagger code. Added openApiDocumentHasBearerScheme MockMvc test. Verified: generated Spring Boot service builds (Maven) + serves /docs (302->200 UI) + /swagger.json (200, OpenAPI 3.0.1, v1, Bearer).
### Changed
- CI links SDK v1.8.0. **Parity table: C#, Python, Go, Node, Java = ALL VERIFIED.**

## [0.8.0] — 2026-07-01 · Node runtime joins the API Documentation Standard (via SDK helper)
### Added
- **Node scaffold consumes @dokandar/platform-sdk `handleDocs`**: server serves Swagger UI /docs + OpenAPI JSON /swagger/v1/swagger.json; securityHeaders uses isDocsPath/DOCS_CSP for the CSP carve-out. No per-service Swagger config. Added an apidocs test (/docs 200 + /swagger.json 200 + Bearer). Verified: generated Node service builds + serves both endpoints (OpenAPI 3.0.3, v1, Bearer).
### Changed
- CI links SDK v1.7.0. Parity: C#, Python, Go, Node = Verified. Java = Pending.

## [0.7.0] — 2026-07-01 · Go runtime joins the API Documentation Standard (via SDK helper)
### Added
- **Go scaffold consumes `.../sdk/go/apidocs`**: server calls `apidocs.Register(mux, serviceName)` (Swagger
  UI /docs + OpenAPI JSON /swagger/v1/swagger.json); SecurityHeaders uses `apidocs.IsDocsPath`/`DocsCSP`
  for the CSP carve-out. No per-service Swagger config. Added `TestAPIDocs` (/docs 200 + /swagger.json 200
  + Bearer). Verified: generated Go service builds + serves both endpoints (OpenAPI 3.0.3, v1, Bearer).
### Changed
- CI links the SDK at **v1.6.0**. Parity table: C#, Python, Go = Verified. Java, Node = Pending.

## [0.6.0] — 2026-07-01 · Python runtime joins the API Documentation Standard (via SDK helper)
### Added
- **Python scaffold now consumes `dkd_platform.apidocs`**: the generated FastAPI service builds with
  `FastAPI(**apidocs.platform_docs_kwargs(...))` + `apidocs.configure_platform_docs(app)` — Swagger UI at
  /docs, OpenAPI JSON at /swagger/v1/swagger.json, Bearer scheme. No per-service Swagger config. CSP
  carve-out for /docs & /swagger. Two TestClient tests assert /docs 200 + /swagger.json 200 (+ Bearer).
- **`docs/api-documentation-standard.md` upgraded to the full 25-section standard** (purpose→DoD +
  runtime parity table). Runtime-agnostic; per-runtime SDK-helper delivery.
### Changed
- CI links the SDK at **v1.5.0** (carries both C# `ApiDocs` and Python `apidocs`).
### Status
- Verified: C#, Python. PENDING: Java, Go, Node (SDK helper + scaffold + verification).

## [0.5.0] — 2026-07-01 · API Documentation Standard is runtime-agnostic + config moved into the SDK helper
### Changed
- **`docs/api-documentation-standard.md` rewritten to be runtime-agnostic** — mandates the behavior and
  URLs only (`/docs`, `/swagger/v1/swagger.json`), not a library. Each runtime implements it with native
  tooling exposed through a platform-SDK helper (§8). No tool is mandated.
- **C# scaffold now consumes the SDK helper** `Dkd.Platform.ApiDocs`: Program calls
  `builder.Services.AddDkdApiDocs(...)` + `app.UseDkdApiDocs()` (one call each). Removed the inline
  Swagger configuration and the `Swashbuckle` package from the generated service csproj — both come
  transitively from the SDK. CI links `dkd-platform-libs` at **v1.4.0** (the SDK carrying `ApiDocs`).
### Verified
- A freshly generated C# service builds 0/0 and passes 8/8 tests (incl. `GetDocs_Returns200` /
  `GetSwaggerJson_Returns200`) using only the SDK helper. Scaffold conformance intact.
### Note
- Java/Go/Python/Node SDK helpers are specified by the standard (native tooling) and are the next step.

## [0.4.0] — 2026-07-01 · platform API Documentation Standard (Swagger) baked into the C# scaffold
### Added
- **`docs/api-documentation-standard.md`** — the mandatory platform-wide Swagger/OpenAPI standard
  (packages, registration, middleware, URLs `/docs` + `/swagger/v1/swagger.json`, endpoint/model/error
  documentation rules, security, versioning, production policy, UI consistency, Definition of Done).
  Extracted from the identity-svc reference implementation.
- **C# emitter now generates Swagger by default:** `Swashbuckle.AspNetCore` package,
  `AddEndpointsApiExplorer()` + `AddSwaggerGen()` (with `CustomSchemaIds`), `UseSwagger()` +
  `UseSwaggerUI(RoutePrefix="docs")`, the CSP carve-out for `/docs` & `/swagger`, and two CI Swagger
  tests (`GetDocs_Returns200`, `GetSwaggerJson_Returns200`). Verified: a freshly scaffolded C# service
  builds 0/0 and passes 8/8 tests including the Swagger checks.
### Note
- Other runtimes (Java/Go/Python/Node) must meet the same standard with their idiomatic tooling; C# is
  the reference implementation. Do NOT reintroduce a second OpenAPI generator (Microsoft.AspNetCore.OpenApi / Scalar).

## [0.3.0] — 2026-06-30 · C# service template fixes (verified by running every runtime)
### Fixed
- **C# service** now compiles and runs against the real SDK: corrected `using Dkd.Platform;` (was
  `using Dkd.Platform.Provenance;` — a class, not a namespace) and the version endpoint now reads
  `Provenance.ContractVersion` / `Provenance.Generator` (was a non-existent `ContractVersion.Value`).
  Root-caused by actually building/running the generated service; `dotnet test` 6/6 + live
  /health /ready /live /version + :9090/metrics confirmed (net10.0).
### Verified
- Go, Node, Python, C# generated services built, tested, started, and curled (all endpoints + metrics)
  locally; Java statically consistent with its SDK; all 5 Helm charts render.

## [0.2.0] — 2026-06-30 · audit remediation + toolchain refresh
### Changed
- All runtime templates updated to latest 2026 stable: Go 1.25, .NET 10 (net10.0), Java 21 + Spring
  Boot 3.5.6, Node 24 + TypeScript 5.7, Python 3.13; infra images postgres 17 / rabbitmq 4.0 / redpanda
  v24.3 / otel-collector 0.115.
### Fixed
- **sample:csharp** now a BLOCKING green gate — the generated C# service is built against the real SDK
  via a ProjectReference local-link (same mechanism as Go/Java/Node/Python), replacing the failed NuGet pack.
- **All 5 sample build+test jobs are now BLOCKING** (removed allow_failure).
### Added
- **helm:render** (helm template every runtime's chart) and **dockerfile:lint** (hadolint every Dockerfile)
  deploy-verification jobs. Sample CI now consumes the SDK at tag v1.2.0.

# Changelog
Format: Keep a Changelog; SemVer.

## [0.1.0] — 2026-06-29 · Phase 3
### Added
- `dkd-scaffold` polyglot service scaffolder: one canonical blueprint + per-runtime emitters.
- Go reference runtime (complete, CI-built against dkd-platform-libs v1.0.0).
- Shared ops layer (Helm, k8s, docker-compose, docs); blueprint-conformance test suite + CI.
