# DOKANDAR API Documentation Standard

## 1. Purpose
Guarantee that every DOKANDAR REST service — in every runtime — exposes an **identical** API
documentation experience with **zero manual work**. A developer must not be able to tell which runtime
a service uses just by opening its docs.

## 2. Scope
All DOKANDAR business services exposing a REST API, across C#/.NET, Java/Spring, Go, Node/TS, Python.
Behaviour and URLs are mandated platform-wide; the implementation is runtime-specific and lives in each
runtime's **platform SDK helper**.

## 3. Version
Standard **v2.0** (runtime-agnostic + SDK-helper delivery). Supersedes the C#-specific v1.

## 4. Owner
Platform / Architecture (Principal Platform Engineer). Changes are ADR-governed (EF §7, ADR-011).

## 5. Status
**ACTIVE — MANDATORY.** New services are non-compliant until they satisfy the Definition of Done (§24).

## 6. Required URLs (fixed — never vary by service or runtime)
| Surface | URL |
|---|---|
| Swagger / OpenAPI UI | **`/docs`** |
| OpenAPI JSON document | **`/swagger/v1/swagger.json`** |

Every service also exposes the standard platform endpoints identically: `/health`, `/live`, `/ready`,
`/version` (plus `/metrics` on the metrics port).

## 7. Required behavior (normative, tool-independent)
- OpenAPI **3.x** document named **`v1`**, title = service slug, served at `/swagger/v1/swagger.json`.
- Interactive UI at `/docs` that loads that document and supports **Try it out**.
- Every endpoint present; every request/response model present as a schema.
- RFC-7807 error contract; Bearer/JWT security scheme; identical tags/ordering/response formatting.
- Content-Security-Policy relaxed **only** on `/docs` + `/swagger`; strict `default-src 'none'` elsewhere.

## 8. Runtime-specific implementation guidance (non-normative tooling)
| Runtime | Native tooling |
|---|---|
| C#/.NET | Swashbuckle.AspNetCore |
| Java/Spring | springdoc-openapi (`springdoc.swagger-ui.path=/docs`, `springdoc.api-docs.path=/swagger/v1/swagger.json`) |
| Go | swaggo (`swag`) + `http-swagger`, or a hand-served spec + Swagger UI assets |
| Node/TS | `swagger-ui-express` / `@nestjs/swagger` (raw-http services serve the UI + spec directly) |
| Python | FastAPI built-in OpenAPI + Swagger UI (`docs_url`, `openapi_url`) |
Any tool is acceptable **iff** it produces §6–§7. Never run two OpenAPI generators in one service.

## 9. SDK helper contract (the single source of behavior)
Each runtime's `dkd-platform-libs` SDK exposes **one helper** that wires §6–§7 so services enable
compliant docs with one/two calls — no per-service Swagger configuration.

| Runtime | Helper |
|---|---|
| C#/.NET | `builder.Services.AddDkdApiDocs("<slug>")` + `app.UseDkdApiDocs()` |
| Python | `app = FastAPI(**apidocs.platform_docs_kwargs("<slug>"))` + `apidocs.configure_platform_docs(app)` |
| Java/Spring | `dkd-apidocs` auto-configuration (starter) — no service code |
| Go | `platformdocs.Register(mux, platformdocs.Options{Title:"<slug>"})` |
| Node/TS | `setupPlatformSwagger(server, { title: "<slug>" })` |

The helper owns: the document (name `v1`), the JSON + UI routes, the Bearer scheme, unique schema ids,
title/description, and (where applicable) the docs CSP. Future changes (§below) are made **only** here.

## 10. Endpoint documentation requirements
Each endpoint carries (in the runtime's native way): a stable **operationId/name**, a **summary**, a
**description**, at least one **tag**, the request media type + schema (writes), and a documented
response for every status it can return (§12). No undocumented endpoints.

## 11. DTO / schema requirements
Every request and response DTO appears in `components.schemas`, including the `{success,data,error,meta}`
envelope and the RFC-7807 `ProblemDetails` shape. Use typed models — never an opaque body.

## 12. ProblemDetails requirements (RFC-7807)
Errors are `application/problem+json` with `dokandar.<context>.<category>.<reason>`. Each endpoint
documents the statuses it can produce: 200/201/202, 400, 401, 403, 404, 409, 422 (if applicable), 500.

## 13. JWT / Bearer requirements
The document declares an HTTP **Bearer** scheme (`type: http, scheme: bearer, bearerFormat: JWT`) so the
UI shows **Authorize**. The gateway injects the token in production. Cross-cutting headers are surfaced
as fillable parameters where used: `Idempotency-Key` (mandatory on unsafe writes), `X-Dkd-Roles`,
`X-Dkd-Caller-Did`.

## 14. Request example
```
POST /v1/parties        Idempotency-Key: 4b1e...   Content-Type: application/json
{ "phoneNumber": "+8801712345678", "deviceId": "d1", "locale": "bn-BD", "otpToken": "000000" }
```

## 15. Response example (envelope)
```
201 Created
{ "success": true, "data": { "did": "did:dokandar:019f..." }, "error": null, "meta": null }
```

## 16. Error example (RFC-7807)
```
403 Forbidden        Content-Type: application/problem+json
{ "type":"about:blank", "title":"Request Error", "status":403,
  "detail":"caller must hold the SYSTEM role", "instance":"/v1/parties/{did}/kyc/approve",
  "code":"dokandar.identity.authz.role_required" }
```

## 17. OperationId rules
- Unique, stable, `PascalCase` verb-noun (e.g. `RegisterParty`, `GetParty`, `ApproveKyc`).
- Never renumber/rename a shipped operationId (client-generation stability; mirrors R6 discipline).

## 18. Tag rules
- Business operations grouped under a single **domain tag** (e.g. `Parties`).
- Platform probes under **`HealthEndpoints`**. Same tag names across services.

## 19. Versioning rules
- OpenAPI **3.x**; API **URL-path major** versioning — external routes are `/v1/...`.
- One document per major, named `v1` at `/swagger/v1/swagger.json`. A new major adds `v2`
  (`/swagger/v2/swagger.json`), selectable in the UI dropdown; shipped documents are never mutated.

## 20. Security policy
Default-deny authorization at the Identity PDP. Docs declare Bearer; `/docs` never leaks secrets; the
OpenAPI document contains no credentials. CSP relaxed only on the docs paths.

## 21. Gateway policy
External traffic (incl. `/docs`) is fronted by the API gateway (OAuth2/OIDC). Services are not exposed
directly in production; the gateway authenticates and forwards the principal.

## 22. Production recommendations
`/docs` is **environment-controlled + gateway-protected**. Enable always in `local`/`dev`/`staging`; in
`production` gate behind the authenticated gateway (internal audiences) or disable via `DKD_ENABLE_DOCS=false`.
Preferred: **gateway-protected**.

## 23. CI verification (pipeline MUST fail on any violation)
Per runtime, CI verifies: build succeeds; **zero warnings**; `/docs` → 200; `/swagger/v1/swagger.json`
→ 200; the OpenAPI JSON is valid; every endpoint appears; every schema appears; the JWT/Bearer scheme
exists; ProblemDetails documented; Try-it-out works (executable). The generated services ship tests that
assert `/docs` 200 and `/swagger/v1/swagger.json` 200 (+ Bearer) so this runs on every pipeline.

## 24. Definition of Done (per service)
- [ ] `/docs` → 200 (UI renders)  · [ ] `/swagger/v1/swagger.json` → 200 (valid)
- [ ] every endpoint present · [ ] every DTO schema present · [ ] Bearer scheme present · [ ] RFC-7807 documented
- [ ] Try-it-out executes · [ ] uses the **SDK helper** (no per-service Swagger config) · [ ] CI verifies the above

## 25. Runtime parity checklist & table
A runtime is **Verified** only when its SDK helper + scaffold exist AND a freshly generated service was
built/run and its `/docs` + `/swagger/v1/swagger.json` proven (evidence recorded).

| Runtime | SDK Helper | Scaffold | CI | Status |
|---|---|---|---|---|
| **C#/.NET** | `Dkd.Platform.ApiDocs` (`AddDkdApiDocs`/`UseDkdApiDocs`), platform-libs v1.4.0 | uses helper (service-template v0.5.0) | build + unit `GetDocs/GetSwaggerJson` + integration | ✅ **Verified** |
| **Python** | `dkd_platform.apidocs` (`platform_docs_kwargs`/`configure_platform_docs`), platform-libs v1.4.0 | uses helper | TestClient `test_docs_ui`/`test_openapi_json` | ✅ **Verified** |
| **Go** | `.../sdk/go/apidocs.Register(mux,title)` (stdlib), platform-libs v1.6.0 | uses helper (service-template v0.7.0) | build + `TestAPIDocs` (/docs + /swagger.json + Bearer) | ✅ **Verified** |
| **Node/TS** | `@dokandar/platform-sdk` `handleDocs(req,res,title)` (stdlib http), platform-libs v1.7.0 | uses helper (service-template v0.8.0) | build + `apidocs` test (/docs + /swagger.json + Bearer) | ✅ **Verified** |
| **Java/Spring** | `DkdApiDocs` auto-config + springdoc (transitive), platform-libs v1.8.0 | uses helper (application.yml paths, service-template v0.9.0) | build + `openApiDocumentHasBearerScheme` test | ✅ **Verified** |

**PARITY ACHIEVED.** All five supported runtimes are implemented and verified with evidence: each ships an
SDK helper, its scaffold consumes that helper (no per-service Swagger config), a freshly generated service
was built and its `/docs` + `/swagger/v1/swagger.json` proven on a live process, and CI asserts the docs
endpoints on every pipeline.

**Runtime note (Java/springdoc):** springdoc serves the Swagger UI by redirecting the configured path, so
`GET /docs` returns **302 → 200** (the UI renders on follow) rather than a direct 200. This is springdoc's
native behavior; the platform contract (open `/docs` → Swagger UI with Try-it-out) is preserved. All other
runtimes return `/docs` → 200 directly.

## Extensibility (future changes touch ONLY the SDK helper)
OAuth2 / OpenID Connect / API keys, themes / branding / CSS, extra headers, operation filters,
correlation-id and tracing surfacing, response conventions — all are added inside the per-runtime SDK
helper. Generated services contain only helper calls, so a platform-wide change is a single SDK release
per runtime, never a per-service edit.
