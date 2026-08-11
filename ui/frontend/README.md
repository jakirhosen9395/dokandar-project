# DOKANDAR Frontend

Next.js (App Router) frontend for the DOKANDAR marketplace. **All frontend work lives here.**
Architecture & plan: [`../FRONTEND_ARCHITECTURE.md`](../FRONTEND_ARCHITECTURE.md) (source of truth).
ADRs: [`docs/adr/`](docs/adr/).

- **Runtime host:** `13.204.65.180` (Node 22 via nvm) — **the toolchain is installed there, not on dev laptops.**
- **Edge:** Browser → **Next.js BFF** (`/api/gw/*`, this app) → **API Gateway `172.31.14.241:10015`** (app server, private VPC IP) → 18 services.
  The browser never calls a service directly; `GATEWAY_URL`/service hosts are **server-only** (never in the client bundle).
- **No CI/CD** — local development + manual deploy only (per scope).

## Stack

Next.js 16 (App Router) · React 19 · TypeScript 5 · Tailwind 4 · shadcn/ui · TanStack Query · Zustand ·
Elastic RUM · OpenAPI codegen (`openapi-typescript` + `openapi-fetch`). React Hook Form + Zod land with the first forms (Phase 2/3).

## Prerequisites

Node.js **22 LTS** + **pnpm** (provisioned on `13.204.65.180` via `nvm install 22 && corepack enable`).

## Setup

```bash
cp .env.example .env.local      # GATEWAY_URL defaults to the app-server private IP; fill secrets
pnpm install                    # native builds (sharp/unrs) are pre-approved in pnpm-workspace.yaml
pnpm gen:api                    # fetch 18 OpenAPI specs + generate typed clients into generated/
pnpm dev                        # http://localhost:3000
```

## Commands

| Command | What it does |
| --- | --- |
| `pnpm gen:api` | Fetch each service `/openapi.json` from `SPEC_HOST` → `generated/openapi/`. Re-run when a backend API changes; review `git diff generated/`. |
| `pnpm dev` / `pnpm build` / `pnpm start` | Dev server / production build / serve build (`:3000`). |
| `pnpm lint` | ESLint. |

## OpenAPI workflow (no CI)

The gateway does **not** expose per-service specs (`/api/v1/<svc>/openapi.json` → 404). `pnpm gen:api`
fetches each service's `/openapi.json` from `SPEC_HOST` (default app-server private IP `172.31.14.241:100NN`)
**at build time, server-side only**, pins snapshots to `generated/openapi/raw/<svc>.json`, generates types
to `generated/openapi/<svc>.ts`, and writes `generated/openapi/MANIFEST.json`. `generated/` is committed +
read-only — regenerate, never hand-edit.

## Docker

Multi-stage build (Node 22, pnpm, standalone output, **non-root**, port 3000, healthcheck on `/health`).
The image uses the **committed** `generated/` types — codegen is a dev step, not run at image build.

```bash
docker build -t dokandar-frontend \
  --build-arg CODE_VERSION=$(cat CODE_VERSION) \
  --build-arg BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --build-arg GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo nogit) .
docker run -d -p 3000:3000 --env-file env/.env.dev dokandar-frontend     # server env at runtime
```

**Env model:** server-only vars (`GATEWAY_URL`, `SPEC_HOST`, `SESSION_COOKIE_SECRET`) are read at
**runtime** (`--env-file`). `NEXT_PUBLIC_*` (e.g. RUM) are inlined at **build time** — pass them as build
args to change them in the image. `env/.env.dev` + `env/.env.prod` are gitignored; `.env.example` is the template.

## Operational endpoints

| Route | Purpose |
| --- | --- |
| `GET /health` | Liveness — lightweight, 200 when the process can serve. |
| `GET /ready` | Readiness — checks gateway reachability + `GATEWAY_URL` + OpenAPI manifest; **503** if any is down. |
| `GET /data` | Operational metadata: service_name, version, environment, build_time, git_commit, node/next version, **masked** gateway_url, observability status, generated-API versions. No secrets. |

```bash
curl -s localhost:3000/health | jq .   ;   curl -s localhost:3000/ready | jq .   ;   curl -s localhost:3000/data | jq .
```

## Manual deploy on 13.204.65.180

```bash
ssh -i mumbai-key.pem ubuntu@13.204.65.180
cd ~/frontend                 # sync source via rsync from the dev repo, then:
pnpm install
pnpm gen:api                  # if backend specs changed
pnpm build
pnpm start                    # :3000 (run under pm2/systemd `dokandar-web` for persistence)
```

## Layout

`app/` routes + `api/gw` BFF proxy + `middleware.ts` guard · `components/` · `features/` · `lib/` (env, auth, rum) ·
`services/` · `generated/` (codegen, read-only) · `stores/` · `hooks/` · `types/` · `styles/` · `public/` ·
`content/devops/` (DEVOPS config) · `scripts/` (fetch-specs).

## Status

- **Phase 1 — Foundation ✅** scaffold · BFF proxy (`/api/gw/*`) · OpenAPI codegen (19 specs) · env model · DEVOPS shell + RBAC · RUM wiring · Docker standalone + ops endpoints (`/health`,`/ready`,`/data`).
- **Phase 2 — Authentication ✅** OTP login/signup · encrypted httpOnly session cookie (BFF-owned refresh, rotation) · in-memory access token · server-enforced RBAC (`/login`,`/verify`,`/logout`,`/forbidden`) · multi-tab + silent refresh.
- **Phase 3 — Marketplace ✅** SSR homepage / search / category / product detail (public catalog+search) · authed cart (optimistic) · wishlist · **working COD checkout** (cart → checkout-package quote → order placement, verified end-to-end → order history). Online payment is the only "coming soon" piece. Gaps GAP-1..6 in COMMAND.md.
- **Phase 4 — Customer Portal ✅** authed `/account` (dashboard, profile, orders + detail, wallet, addresses w/ RHF+Zod geo cascade, notifications polling, reviews) + enhanced wishlist. CSR via BFF + TanStack Query. Gaps GAP-7..11 in COMMAND.md.
- **Phase 5 — Seller Portal ✅** (heavily backend-gated) `/seller` shell (10 routes, shopkeeper/shop_staff RBAC). Functional: product create/edit/stock (draft) + coupon listing. Blocked w/ honest empty states: orders, media, analytics, shop, publish. Gaps GAP-12..19 in COMMAND.md.
- **Phase 6 — Admin Portal ✅** `/admin` (admin/platform_staff): dashboard (platform KPIs + charts), payments, reports, risk, users/KYC, wallets, system health + observability. Real reporting/payment/risk data. Gaps GAP-20..22.
- **Phase 7 — DEVOPS Portal ✅** operational handbook: architecture, 18-service catalog, API explorer (server-side OpenAPI proxy), infrastructure, observability, 9 runbooks, in-repo doc viewer.
- **Phase 8 — Observability + Hardening ✅** CSP + secure headers, error boundaries, Query retry policy, trace correlation, dependency audit (1 moderate transitive), non-root Docker, cold-start <1s.
- **Resilient gap UX ✅** every backend gap has a frontend mitigation (Category A — fixed: search facets, guest cart, shipment tracking, wishlist…) or a resilient state (B/C — branded placeholders, live diagnostics, remediation cards, local media queue). No dead-ends. Full matrix + readiness scores: [GAP_REGISTER.md](GAP_REGISTER.md).
