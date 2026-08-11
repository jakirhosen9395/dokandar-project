# ADR 0001 — Frontend Foundation

- **Status:** Accepted
- **Date:** 2026-06-21
- **Context:** Phase 1 (Foundation) of the DOKANDAR frontend, on the dedicated host `13.204.65.180`,
  fronting the API Gateway `172.31.14.241:10015` (app server, private VPC IP) → 18 microservices.

## Decisions

1. **Next.js 16 App Router + Node runtime.** SSR/RSC for SEO-critical marketplace pages and a built-in
   BFF (Route Handlers + `middleware`). Node runtime (not Edge) — the BFF needs Node APIs (cookies,
   custom-header server fetch, traceparent injection) and the app is self-hosted on EC2.

2. **BFF gateway proxy is the only egress.** Browser → `/api/gw/*` (this app, server-side) → `GATEWAY_URL`.
   `GATEWAY_URL`/service hosts are non-`NEXT_PUBLIC` ⇒ never in the client bundle (security requirement).
   Verified: `/api/gw/search/products` returns real backend JSON; internal IPs never reach the browser.

3. **Gateway does not expose per-service Swagger** (verified: `/api/v1/<svc>/openapi.json` → 404). So
   OpenAPI types are generated at **build time** by fetching each service's `/openapi.json` from
   `SPEC_HOST` (private IP), pinned under `generated/openapi/raw/` + `MANIFEST.json`. Tool:
   `openapi-typescript` + `openapi-fetch` (lighter + more predictable than `orval` for 18 specs).

4. **Trace correlation via BFF injection, not gateway CORS.** A live OPTIONS preflight from a
   non-allowlisted origin returned 405; the gateway CORS `Allow-Headers` lacks `traceparent`. The BFF
   injects `traceparent` + `x-request-id` server-side, so Browser(RUM) → BFF → Gateway → Service share
   one trace with zero backend change.

5. **RBAC at the edge.** `middleware.ts` gates `/devops` + `/admin` to `{admin, platform_staff}`,
   `/seller` to `{shopkeeper, shop_staff}`, `/account` to authenticated roles. Verified:
   no-role → 307 /login, admin → 200, customer → 404 (area hidden). The real signed session cookie is
   wired in Phase 2; the foundation reads a placeholder role cookie.

6. **State split.** TanStack Query for server-state (RSC for initial loads, hydrate for interactivity);
   Zustand for client-only UI state + in-memory access token; no server data in Zustand.

7. **No CI/CD** (per scope). Manual `pnpm gen:api` + `git diff generated/` review; manual deploy on the
   server. `generated/` is committed + read-only.

## Consequences / follow-ups

- Next 16 deprecates `middleware.ts` in favour of `proxy.ts` — functional now (build warning only);
  rename tracked as a deviation.
- `server-only` import guard not yet added (relying on Next's `NEXT_PUBLIC` rule); add in hardening.
- Phase 2 replaces the placeholder role cookie with the OTP login + signed session.
