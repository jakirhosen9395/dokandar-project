# DOKANDAR — Frontend Architecture & Implementation Plan

> **Discovery + architecture only — no production code / components / config files.** Every claim is
> grounded in repository files, verified OpenAPI, or live-gateway checks done this session.
> **CI/CD is explicitly out of scope** — only local development + manual deployment on `13.204.65.180`.
> Implementation will live entirely in `/home/jakir/Desktop/clone/frontend/`.

## Deployment topology (given + verified)

| Server | IP | Path | Role |
| --- | --- | --- | --- |
| utility | 65.0.97.73 | `/opt/utility` | Backing infra (Postgres, Kafka, RabbitMQ, NATS, Redis, ES `:9200`/`:9201`, Mongo, Qdrant, Scylla, Neo4j, MinIO, Temporal) |
| app | 65.2.81.217 | `/home/ubuntu` | 18 microservices (Docker); edge = **API Gateway `:10015`** |
| frontend | 13.204.65.180 | `/home/jakir/Desktop/clone/frontend` (repo) → built/served on the box | Next.js (Ubuntu 26.04, 2 vCPU / 7.6 GiB / 17 GB; **git only — node/pnpm to install**) |

**Verified path:** `13.204.65.180 → 65.2.81.217:10015/ready` → 200, `/api/v1/search/products` → 200. Browser reaches **only** the Next.js BFF (same-origin); the BFF reaches the gateway server-side.

---

## 1. Repository findings (Phase 1)

| Doc | Status | Used for |
| --- | --- | --- |
| `overview/README.md` (4930) | ✅ | fleet §6, ports §7, per-service §10, contract §13 |
| `overview/architecture.md` (1023) | ✅ | 5-endpoint contract §10, seam map §21, observability §13, drift §22 |
| `overview/SERVICE_ENV_BUILD_STANDARD.md` | ✅ | env conventions, two-ES rule (`:9200` APM-logs / `:9201` business search) |
| `overview/SERVICE_INTEGRATION_TEMPLATE.md` | ✅ | per-stack landmines, build→integrate→test |
| root `README.md`, `docs/`, `docs/adr/` | ❌ **absent** | the four `overview/*.md` are the authoritative docs |

Platform invariants: single edge (`15-api-gateway`, Go/Echo); every service exposes `/ready /health /data /metrics /docs /openapi.json` + shared identity block; **error envelope** `{error:{code,message,request_id,details}}` (snake codes); **integer paisa**; **bn/en** UTF-8; **COD ~70%**.

---

## 2. Verified API inventory (Phase 2)

Gateway surface (`http://65.2.81.217:10015` in dev). Source: gateway route table (`15-api-gateway/internal`) + per-service OpenAPI + live probes.

| # | Service | Gateway base path | Edge auth | Frontend | Rate-limit |
| --- | --- | --- | --- | --- | --- |
| 00 | support | `/api/v1/support/*` | Bearer | ❌ internal | 120/1s |
| 01 | auth | `/api/v1/auth/*` | **public** | ✅ | global fail-open |
| 02 | profile | `/api/v1/profile/*` | Bearer (geo public) | ✅ | global |
| 03 | seller | `/api/v1/seller/*` | Bearer | ✅ seller | global |
| 04 | catalog | `/api/v1/catalog/*` | **public** | ✅ | global fail-open |
| 05 | search | `/api/v1/search/*` | **public** | ✅ | **120/1s** fail-open |
| 06 | cart | `/api/v1/cart/*` | Bearer (guest public) | ✅ | global fail-closed |
| 07 | coupon | `/api/v1/coupon/*` | Bearer (festivals public) | ✅ | global |
| 08 | review | `/api/v1/review/*` | Bearer (reads public) | ✅ | global |
| 09 | payment | `/api/v1/payment/*` | Bearer | ⚠️ status only (intents/webhooks internal) | **20/1s tight** |
| 10 | wallet | `/api/v1/wallet/*` | Bearer | ✅ | global fail-closed |
| 11 | reporting | `/api/v1/reporting/*` | Bearer | ✅ seller/admin | global |
| 12 | media | `/api/v1/media/*` | **public** (presign authed) | ✅ | global fail-open |
| 13 | order | `/api/v1/order/*` | Bearer | ✅ | global fail-closed |
| 14 | notification | `/api/v1/notification/*` | Bearer | ✅ | global fail-closed |
| 15 | api-gateway | `/api/v1/bff/home` + ops | Bearer (bff) | ✅ | global |
| 16 | recommendation | `/api/v1/recommendation/*` | Bearer (some public) | ✅ | global |
| 17 | shipping | `/api/v1/shipping/*` | Bearer | ✅ | global |
| 18 | risk-trust | `/api/v1/risk/*` | Bearer | ❌ internal scoring | global |

**RESOLVED (live, this session): the gateway does NOT expose/aggregate per-service Swagger.** `/api/v1/{search,catalog}/openapi.json` → **404**, `/api/v1/catalog/docs` → **404**; gateway `/openapi.json` lists only `/api/v1/bff/{path}`, `/data`, `/health`, `/metrics`, `/ready`. → specs are collected **at build time** (§8) and the DEVOPS explorer **proxies** them server-side (§10).

---

## 3. Frontend architecture (Phase 3) + technology evaluation

**Topology:** `Browser → Next.js App Router (BFF + SSR/RSC, on 13.204.65.180) → Gateway :10015 → services`. Next.js is both the renderer (SEO) and the **BFF** (holds refresh cookie, injects `traceparent`+`x-request-id`, proxies to the gateway server-side so the gateway URL is never in client code and CORS is avoided).

| Tech | Fit | Drawback | Alternative | Verdict |
| --- | --- | --- | --- | --- |
| Next.js App Router | SEO (product/category/search) via RSC+SSR; native BFF Route Handlers; streaming; i18n | RSC model; caching foot-guns | Remix; Vite SPA (no SEO) | **Adopt** |
| TypeScript | typed client from 18 specs | — | — | **Adopt** |
| Tailwind | dense Amazon grids, dark tokens | verbose markup | CSS Modules, Panda | **Adopt** |
| shadcn/ui | Radix = WCAG AA; own the code | copy-in upkeep | Radix Themes, MUI, Park UI | **Adopt** |
| TanStack Query | read-heavy REST, cache/infinite-scroll, optimistic cart | overlaps RSC fetch | SWR, RTK Query | **Adopt, scoped** (RSC for initial loads) |
| Zustand | UI state + in-memory access token | misuse for server data | Jotai, Redux, Context | **Adopt, narrow** |
| React Hook Form | checkout/address/seller forms | — | Formik, TanStack Form | **Adopt** |
| Zod | runtime validation, gate input | bundle for big schemas | Valibot, Yup | **Adopt** (hand-authored for write-forms) |
| OpenAPI codegen | one typed client | gateway serves no specs → build-time fetch | manual types | **Adopt** — `openapi-typescript`+`openapi-fetch` (see §8) |
| Elastic RUM | backend is Elastic APM; correlate via `traceparent` | RUM agent → OTel transition; CORS gap | OTel-web → OTLP | **Adopt** (trace via BFF, §12) |

---

## 4. User role matrix (Phase 4)

Roles (`01-auth/app/db/models.py:11-14`): **`customer, shopkeeper, shop_staff, platform_staff, admin`** + Guest. JWT (`tokens.py:49-66`): `sub, role, phone, lang, kyc, iss, iat, exp, jti`; access **15 min**, refresh **30 day opaque**. "Operations" + "Support" → both **`platform_staff`** (one backend role).

| Role | Routes | Permissions | Primary APIs |
| --- | --- | --- | --- |
| Guest | `/`,`/c/*`,`/search`,`/p/*`,`/store/*`,`/cart`,`/login` | browse, guest cart, auth | catalog, search, media, review(read), coupon/festivals, cart/guest, auth |
| Customer | + `/account/*`,`/checkout` | own cart→checkout, COD/wallet pay, track, review purchased, profile/addresses | cart, order, payment(status), wallet, profile, notification, review, recommendation |
| Seller (`shopkeeper`) | + `/seller/*` | shop, products/inventory, coupons, media, seller orders, analytics | seller, catalog(write), coupon, media, order(seller), reporting |
| Seller staff (`shop_staff`) | `/seller/*` (restricted) | scoped subset | catalog, order(seller), media |
| Ops/Support (`platform_staff`) | `/admin/*` (read), `/devops` | view users/sellers/orders/payments/risk/health; no destructive | reporting, order, payment(read), profile/admin |
| Admin (`admin`) | `/admin/*`, `/devops` (full) | provision any role, full ops | auth/admin, all surfaces |

Provisioning (`auth.py:47-51`): admin→all; shopkeeper→shop_staff,customer; shop_staff→customer; customer self-signup only.

---

## 5. Route map

```
PUBLIC   /  ·  /c/[...slug]  ·  /search  ·  /p/[id]/[slug]  ·  /store/[handle]  ·  /cart  ·  /checkout  ·  /login /signup
CUSTOMER /account/*   (guard customer):  dashboard·orders·orders/[id]·wallet·addresses·reviews·wishlist·notifications
SELLER   /seller/*    (guard shopkeeper|shop_staff): dashboard·products·products/[id]·inventory·orders·coupons·media·analytics
ADMIN    /admin/*     (guard admin|platform_staff): dashboard·users·sellers·payments·reports·risk·system-health
DEVOPS   /devops/*    (guard admin|platform_staff): architecture·catalog·api-explorer·ops-endpoints·infrastructure·observability·local-dev·runbooks·docs
```

---

## 6. Component hierarchy (top level)

```
<RootLayout> (Theme dark/light · Locale bn/en · QueryProvider · RUMProvider · AuthProvider)
├─ <MarketplaceShell> Header(SearchBar,CategoryMega,CartBadge,AccountMenu,LocaleToggle)·Footer
│   Home(Hero,DealsRail,RecoFeed,CategoryGrid)·ProductGrid/Card/FacetSidebar·ProductDetail(Gallery,BuyBox,SellerBadge,Reviews,SimilarRail)·Cart·Checkout(Address[BD geo],Shipping,Payment[COD/Wallet],ReviewPlace)
├─ <PortalShell customer> OrderCard·WalletLedger·AddressForm·ReviewForm·WishlistGrid·NotificationInbox(WS)
├─ <PortalShell seller>   ProductEditor·InventoryTable·SellerOrderTable·CouponBuilder·MediaUploader(presign)·AnalyticsCharts
├─ <PortalShell admin>    UserTable·SellerTable·PaymentTable·ReportViewer·RiskBoard·HealthGrid
└─ <DevopsShell>          ServiceCatalog·ApiExplorer·OpsEndpointGrid·InfraInventory·ObservabilityLinks·RunbookViewer·MarkdownDocViewer
Primitives (shadcn): Button·Input·Select·Dialog·Sheet·Table·Tabs·Toast·Badge·Skeleton·Command
```

---

## 7. State management strategy

- **Server state → TanStack Query** (catalog/search/orders/wallet/reviews); RSC does initial SSR loads, then hydrate for interactivity (no double-fetch).
- **Client state → Zustand** (cart drawer, theme, locale, in-memory access token, optimistic cart). No server data.
- **Forms → RHF + Zod** (hand-authored schemas for write-forms; BD-address cascade via dependent queries).
- **Session →** access token in memory; refresh token httpOnly Secure SameSite cookie (BFF-set); silent refresh on 401.
- **Realtime →** notification inbox via WS/NATS through gateway **[GAP-3]**; fallback polling.
- **Idempotency →** per-checkout UUID `Idempotency-Key` persisted in Zustand across retries; `409` → poll order status.

---

## 8. API integration strategy + OpenAPI workflow (Phase 3, item 2)

**Browser → gateway only:** all client calls hit the Next.js BFF (`app/(bff)` Route Handlers / server actions) which proxies to `65.2.81.217:10015/api/v1/*`. `GATEWAY_URL` is **server-only** (never `NEXT_PUBLIC_*`).

**OpenAPI workflow (manual, no CI):**
| Aspect | Decision |
| --- | --- |
| Source of truth | each running service's `GET /openapi.json` (generated from standardized service code). Pinned snapshot committed under `generated/openapi/raw/<svc>.json`. |
| Spec collection | Gateway serves no specs (404, §2) → **build-time fetch** from per-service ports on the app host (dev: `65.2.81.217:100NN/openapi.json`). Used **only at build time, server-side on the dev box** — never in the browser bundle. |
| Tool | **`openapi-typescript`** (types) + **`openapi-fetch`** (typed runtime client used inside the BFF). Rationale: lightest, predictable, handles 18 specs; thin TanStack Query wrappers hand-written. **Alternative:** `orval` if auto-generated TanStack hooks + Zod are preferred. |
| Generation command | local `pnpm gen:api` → `node scripts/fetch-specs.mjs` (fetch 18 → `generated/openapi/raw/`) → `openapi-typescript` per spec → `generated/openapi/<svc>.d.ts`; write `generated/openapi/MANIFEST.json` (svc→`info.version`+timestamp). |
| Output dir | `frontend/generated/openapi/raw/<svc>.json` · `frontend/generated/openapi/<svc>.d.ts` · `frontend/generated/api/<svc>.ts` (openapi-fetch client bound to the BFF base). `generated/` is committed + read-only (regenerate, don't edit). |
| Regeneration | backend API changes → run `pnpm gen:api` locally → review `git diff generated/` → commit. Developer-initiated. |
| Versioning | each spec's `info.version = code_version`; pinned in `MANIFEST.json`; the frontend bumps its spec set deliberately. No automated drift detection. |

**Per-call:** propagate/mint `x-request-id`; `Idempotency-Key` on checkout/order/payment; inject `traceparent` server-side (§12); map error envelope → typed UI errors + toast (surface `request_id`); respect `429` (payment 20/1s → disable submit).

---

## 9. Design system specification

Tailwind semantic tokens (light/dark) · Amazon-dense spacing · trust palette (verified/COD/in-stock). i18n bn+en via `next-intl` (LTR; localized numerals; **paisa→৳**). WCAG AA (Radix focus/ARIA, ≥4.5:1 both themes, skip-links, reduced-motion). Mobile-first (bottom-nav, search-first) → desktop mega-menu + dense grid + sticky BuyBox. Trust UI (KYC/verified badges, ratings, ETA, COD eligibility, returns). Perf: `next/image` for media signed URLs, route code-split, skeletons, hover-prefetch, ISR for catalog/category.

---

## 10. DEVOPS portal specification (`/devops`) — expanded (item 4)

**Auth/RBAC:** `/devops/*` requires session role ∈ {`admin`,`platform_staff`}, enforced in **middleware + every Route Handler** (server-side, not client redirect). Unauthorized → 404 (don't reveal existence). All data flows through **server-side proxies** — internal URLs/ports never reach the browser.

**Service catalog — schema** (static config `content/devops/services.ts`, sourced from CLAUDE.md fleet table + `env/*.example`; no live URLs in it):
```
ServiceEntry {
  id, name, description(boundedContext), language, framework,
  repoPath: "backend/<svc>", ports:{ inContainerRest, inContainerGrpc?, externalRest:"100NN", externalGrpc?:"200NN" },
  datastores: string[], dependencies: { kafkaIn[], kafkaOut[], grpc[], rest[] },
  envVars: { name, required, secret, description }[], owner  // owner = config placeholder [ASSUMPTION]
}
```

**Operational endpoint discovery:** the contract guarantees all six per service, so the list is **static** (`/health /ready /metrics /data /docs /openapi.json`), probed via a server-side proxy `app/devops/api/[svc]/[endpoint]/route.ts` that maps `svc→internal host:port` from a **server-only** `SERVICE_HOSTS` env map and returns status + JSON. Browser calls `/devops/api/<svc>/health` (same-origin); live status chips.

**API explorer:** embedded Swagger UI loading `/devops/api/<svc>/openapi.json` (server-proxied from `65.2.81.217:100NN/openapi.json`). Shows base path (`/api/v1/<svc>`) + auth method. No internal URL exposed.

**Infrastructure inventory** (verified §21 + CLAUDE.md): Kafka topic→producer→consumers table; RabbitMQ (`payout.execute`, `notifications.{email,sms,push,whatsapp,otp}`, `media.*`); NATS (notification WS inbox); Temporal (`CheckoutSaga`@13-order); datastores (Postgres `dokandar_<svc>_<env>`, Redis DB#, Mongo, ES, ClickHouse, Neo4j, Qdrant, ScyllaDB, MinIO buckets).

**Observability:** 3 log sinks (stdout · Mongo `mongo_db_dokandar_application_logs.<svc>` · ES `logs-app-<svc>-*`@`:9200`); Elastic APM (service.name join key, intake `:8200`); two-ES rule (`:9200` APM-logs all / `:9201` business search 05+08); trace-correlation/service-map/error-tracking explainer. Kibana/APM URLs = config `[ASSUMPTION: not in repo]`.

**Local development:** identity-DAG startup order (auth → profile/seller → commerce → order → intelligence); env render (`init-env.sh`); `commands.md` build/run; `data/<tenant>/collect.sh` seed; `smoke_test/test.sh` gate.

**Runbooks (outlines):** Kafka down (outbox buffers; `<svc>_outbox_pending`; don't evict pods) · DB fail (`/ready` 503; ensure_db retry) · missing traces (APM not outermost / `-javaagent` not attached) · health-check fail (which dep; JWT public-key drift = #1 bug) · Temporal worker down (saga stalls; replays on recovery).

**Documentation viewer:** renders `overview/*.md` (+ root README if added). Markdown **indexing/search**: at build, parse `overview/*.md` → headings→TOC + a flat text index (`content/devops/docs-index.json`); client search via Fuse.js/FlexSearch over that index; markdown sanitized before render. Source dir configurable (`overview/`, future `docs/`).

---

## 11. Security model

Access token in memory; refresh in **httpOnly Secure SameSite=Lax cookie** (BFF-set). Route guards in middleware **and** RSC/Route Handlers (server-enforced); backend remains authority. Strict **CSP** (`default-src 'self'`; connect-src self+RUM; img-src media/CDN; nonce scripts). XSS: React escaping + sanitize markdown/reviews; no `dangerouslySetInnerHTML` on user content. **Internal URLs never in client bundle** — `GATEWAY_URL`/`SERVICE_HOSTS` server-only; DEVOPS proxies all service URLs. CSRF on cookie-authed BFF mutations (SameSite + token). `/devops` RBAC server-enforced.

---

## 12. Observability plan — `traceparent` resolved (item 3)

| Approach | Pros | Cons |
| --- | --- | --- |
| **A. Gateway CORS update** (add `traceparent,tracestate` to Allow-Headers + frontend origin to `CORS_ALLOWLIST`) | browser calls gateway directly with trace headers | backend change + redeploy; CORS fragile (**live: OPTIONS preflight → 405** for non-allowlisted origin); exposes gateway URL to browser; still need BFF for tokens |
| **B. BFF trace injection** ✅ | no backend change; no CORS gap; gateway URL stays server-only; one place to inject `traceparent`+`x-request-id`+user ctx; works today | trace has RUM segment + BFF-server segment that must be linked |

**Recommendation: B (BFF trace injection).** Rationale: the BFF is already in the path for auth, CORS is proven fragile, and it keeps internal URLs hidden with zero backend change.

**Trace flow:** `Browser (Elastic RUM, root trace) → BFF Route Handler (continues from RUM traceparent; server span) → Gateway (edge span) → Service (transaction)` — one `trace.id`, unified in the APM Service Map (`dokandar-web → gateway → <svc>`).
- **Elastic RUM:** client provider; `service.name=dokandar-web`, env, version; capture page-load/route-change/long-tasks/JS-errors/API-timings.
- **Browser OpenTelemetry (alt/complement):** OTel-web SDK → OTLP-HTTP via the BFF; RUM is the native fit since backend is Elastic APM.
- **User/session correlation:** after login set RUM user ctx `{id:sub, role, locale}` (no PII); per-session UUID; forward as `x-request-id`/baggage so backend logs (carry `request_id`+`trace.id`) join to the user.

---

## 13. Deployment architecture (item 6)

- **Runtime:** **Node** (not Edge) — the BFF needs Node APIs (cookies, custom-header server fetch, traceparent injection) and is self-hosted on EC2; `next build` with `output:"standalone"` → `node server.js`.
- **Rendering per route category:**
  - **SSR (dynamic):** Home (personalized BFF), Search, Cart, Checkout, all `/account /seller /admin /devops` (authed).
  - **ISR (revalidate):** Product detail, Category, Seller storefront (SEO + cacheable; TTL or on-demand revalidate on `product.changed`/`shop.changed` later).
  - **CSR:** interactive islands inside SSR shells (facet filter, infinite scroll, cart drawer) via TanStack Query.
- **CDN/assets:** product media via 12-media **presigned URLs** + `next/image`; Next static assets served by Node (dev) — optional nginx reverse-proxy on the box; **prod would front with a CDN** (out of scope now).
- **Env management:** committed `.env.example` (schema only); rendered `.env.local` on `13.204.65.180` (gitignored) — mirrors the backend `init-env` convention. **Server-only:** `GATEWAY_URL`, `SERVICE_HOSTS` (DEVOPS map), `SESSION_COOKIE_SECRET`, `INTERNAL_TOKEN` (if BFF needs it). **`NEXT_PUBLIC_*`:** only non-secret client config (RUM endpoint+service name, default locale).
- **Topology on 13.204.65.180 (manual):** install Node 22 + pnpm → `pnpm install` → `pnpm gen:api` → `pnpm build` → run via `pnpm start` (or pm2/systemd unit `dokandar-web`) on `:3000`; reachable at `13.204.65.180:3000`; BFF → gateway `65.2.81.217:10015` server-side. **Manual redeploy:** `git pull` (or rsync) → `pnpm install` → `pnpm gen:api` (if specs changed) → `pnpm build` → restart. No pipelines.

---

## 13a. Foundation hardening — Docker + operational endpoints (implemented)

**Dockerization (backend operational parity):** multi-stage `Dockerfile` — `deps` (pnpm `--frozen-lockfile`)
→ `build` (`next build`, `output: "standalone"`, using the **committed** `generated/` types — no network
codegen at image build) → `runner` (`node:22-alpine`, **non-root** user `nextjs:nodejs`, `EXPOSE 3000`,
`HEALTHCHECK` on `/health`). `.dockerignore` excludes `node_modules`/`.next`/`.git`/env secrets.
Supports local + EC2 + future K8s (12-factor: config via env, stateless,
healthcheck, non-root). **Env split:** server-only vars at runtime (`--env-file env/.env.dev|prod`);
`NEXT_PUBLIC_*` baked at build (pass as `--build-arg`). `env/.env.dev` + `env/.env.prod` gitignored.

**Operational endpoints (mirror the backend contract):**
- `GET /health` — liveness, lightweight, 200 when serving.
- `GET /ready` — readiness: API-Gateway reachability + `GATEWAY_URL` present + OpenAPI manifest available; **503** if any traffic-critical dep is down.
- `GET /data` — operational metadata: `service_name`, `version` (CODE_VERSION), `environment`, `build_time`, `git_commit`, `node_version`, `next_version`, **masked** `gateway_url`, observability status, generated-API versions. No secrets.

`COMMAND.md` carries the copy-paste runbook (dev / OpenAPI / Docker / observability / operations / troubleshooting).

## 13b. Phase 2 — Authentication (implemented + verified)

**Discovery (live, not assumed):** OTP login/signup (`/login|signup/{request,verify}`), `/refresh` (rotates),
`/logout` (204 revoke), `/me`, `/jwks`. Token bundle `{access_token(RS256,15m), refresh_token(64-char opaque,
rotating), expires_in, user}`; claims `{sub,role,phone,lang,kyc,iss,exp,jti}`; roles `customer · shopkeeper ·
shop_staff · platform_staff · admin`.

**Token model:** access token in memory (Zustand); refresh token inside an **encrypted (JWE A256GCM) httpOnly
SameSite=Lax session cookie the BFF owns** — also carries `{sub,role,kyc}` so the Edge middleware does RBAC
without a round-trip. Browser never sees the refresh token; nothing in localStorage/sessionStorage.

**BFF auth routes (cookie lifecycle):** `POST /api/auth/verify` (login/signup → seal cookie, return access+user,
no rt) · `POST /api/auth/refresh` (rotate) · `GET /api/auth/session` (cold-load/new-tab bootstrap) ·
`POST /api/auth/logout` (gateway revoke + clear cookie). Public `*/request` go via the generic `/api/gw` proxy.

**Client:** single-flight refresh, **silent refresh ~60s before expiry**, **multi-tab sync via BroadcastChannel**,
`authedFetch` (attach Bearer; 401 → refresh once → retry). User profile is **TanStack Query `['me']`** (server
state, seeded on login) — not duplicated in Zustand.

**Route protection (`middleware.ts`, Edge, jose):** reads the encrypted cookie → no session ⇒ **307 → /login**;
wrong role ⇒ **rewrite to /forbidden (403 page)**. Gates `/devops · /admin · /seller · /account`. Pages:
`/login · /verify · /logout · /forbidden` (bn/en, dark, mobile-first).

**Security:** httpOnly + (prod) Secure + SameSite=Lax cookie; JWE-encrypted payload (rt never readable);
**CSRF** via same-origin check on cookie mutations; **rotation + backend revoke** (replay → session killed);
XSS-safe (no token in JS-readable storage); gateway/internal IPs server-only. **Observability:** BFF injects
`traceparent`+`x-request-id` on auth calls; RUM user context set on login, cleared on logout.

## 13c. Phase 3 — Marketplace (implemented + verified)

**Discovery (live):** catalog (`categories/tree`, `products`, `products/{id}`) + search (`products?q,category_id,page,size`,
`autocomplete`, `trending`) are **public**; reviews, recommendations, cart, and the seller storefront are **Bearer-gated**.

**Routes:** `/` · `/search` · `/category/[slug]` · `/product/[productId]` · `/cart` · `/checkout` · `/wishlist` · `not-found`.
**Render strategy:** public discovery (home/search/category/product) is **SSR** via `lib/api-server.publicGet` (server-side
gateway fetch with traceparent); cart/reviews/recs/add-to-cart are **CSR** via the BFF + `authedFetch` + TanStack Query.
State: server data in Query (`['cart']`,`['me']`,`['review-agg']`,`['similar']`), UI-only in Zustand — no duplication.
Optimistic qty update + rollback in `useCart`.

**GAP register (Phase 3):** GAP-1 seller storefront unreachable (gateway `/api/v1/seller/*` ≠ service `/api/v1/shop/*`,
404 even authed — **backend fix needed**); GAP-2 search filters limited to `category_id`; GAP-3 reviews+recs Bearer-gated;
GAP-4 guest cart 401 (cart requires login); GAP-5 product images absent from public catalog/search (placeholder);
GAP-6 product detail lacks `shop_id` for cart (carried via `?shop=`). **Checkout** = foundation only; payment disabled + "coming soon".

**Verified (container):** homepage/search/product render real data; guest cart prompts login; auth + authed cart/me intact; Docker 283 MB, healthy.

## 13d. Phase 4 — Customer Portal (implemented + verified)

**Routes (all gated to authed roles by middleware):** `/account` (dashboard) · `/account/profile` · `/account/orders` ·
`/account/orders/[orderId]` · `/account/wallet` · `/account/addresses` · `/account/notifications` · `/account/reviews` ·
`/wishlist`. Unauth → **307 /login** (verified).

**Render strategy:** the authed portal is **CSR** (client components + `authedFetch` + TanStack Query) — the access token
lives in client memory, so per-request SSR would force an rt-rotating refresh; skeletons cover the initial load. Data layer:
`lib/services/account.ts` (all via BFF → gateway). Server state in Query (`['orders']`,`['wallet']`,`['addresses']`,
`['inbox']`,`['profile']`,`['my-reviews']`,`['wishlist']`); UI state in Zustand only. Forms: **React Hook Form + Zod**
(address create with BD division→district→upazila→union geo cascade; profile edit). Optimistic: wishlist remove, cart qty.
Notifications: **polling** (30s) — realtime is NATS, not REST (GAP-9).

**GAP register (Phase 4):** GAP-7 order list lacks backend filter/page params (client-side filter) · GAP-8 shipment
tracking (17-shipping) absent from the customer gateway set · GAP-9 notifications realtime is NATS (polling instead) ·
GAP-10 review-list "mine" filter unverified · GAP-11 `profile/me` 404 until the Kafka profile projection lands for new
users (page degrades gracefully). Wallet top-up endpoint exists but needs the payment phase.

**Verified (container, fresh-customer session):** all 8 routes 200 authed / 307 unauth; BFF data (orders, wallet, inbox,
addresses, geo, wishlist) 200; **zero regression** (home/search/product/cart/login/devops/health/ready/data all green); 285 MB, healthy.

## 13e. Phase 5 — Seller Portal (implemented; heavily backend-gated)

**Routes (gated to shopkeeper + shop_staff by middleware):** `/seller` · `/seller/products` · `/seller/products/new` ·
`/seller/products/[productId]` · `/seller/inventory` · `/seller/orders` · `/seller/orders/[orderId]` · `/seller/coupons` ·
`/seller/media` · `/seller/analytics`. customer → **/forbidden (403)**, unauth → **307 /login** (verified).

**Capability split (live-verified with a privileged token):** **Functional** — product create/edit (catalog POST/PUT,
creates `status:draft`), per-variant stock (PUT /catalog/stock), coupon listing (`coupon/coupons/me`). **Blocked at the API
boundary (honest empty/blocked states, no mocks)** — seller orders (GAP-13), media library (GAP-15 internal MinIO host /
GAP-16 list 404), analytics (reporting not exposed), shop setup/storefront (GAP-1), product publish (`list-in-shop` needs a
shop, GAP-1), coupon create (`scope=shop` needs `shopId`, GAP-1; activation is admin `approve`, GAP-14).

**GAP register (Phase 5):** GAP-12 catalog list not seller-scoped · GAP-13 no seller order list · GAP-14 coupon activation
admin-gated · GAP-15 media presign → internal MinIO host · GAP-16 media list 404 · GAP-17 catalog write schemas undocumented
in OpenAPI (read from `backend/04-catalog`) · GAP-18 no inventory-history API · GAP-19 shopkeeper not self-serviceable at
signup + no admin role-assign endpoint → seller-authed flows unexercisable in this environment. **No charting lib added** —
analytics has no data, so an unavailable state is shown rather than fabricated charts.

**Verified (container):** 10 routes build; RBAC customer→403 / unauth→307; data path product-create **201** + coupons/me **200**
(privileged token); **zero regression**; 287 MB, healthy, non-root. Authed-shopkeeper render limited by GAP-19.

## 13f. Phase 6 — Admin Portal (implemented + verified, richly backed)

**Routes (admin + platform_staff):** `/admin` · `/admin/users(+[id])` · `/admin/sellers(+[id])` · `/admin/orders` ·
`/admin/payments` · `/admin/wallets` · `/admin/reports` · `/admin/risk` · `/admin/notifications` · `/admin/system`.

**Functional (real data via reporting/payment/risk/auth-kyc):** dashboard (platform-kpis GMV/orders/AOV/take-rate +
orders-by-period CSS bar chart + payment-mix), payments (payouts/commission-rates/COD ledger), reports, risk (rules +
create), users (KYC queue approve/reject + per-user profile/wallet lookup), wallets (per-user balance), system (ops status +
18-service catalog + observability model). **Blocked (honest states):** sellers (GAP-1), per-order monitoring (GAP-13),
admin notifications (GAP-21). **No charting lib** — orders chart is pure CSS bars.

**GAP register (Phase 6):** GAP-20 no user-list API (lookup-by-id only) · GAP-21 no platform-wide notification API ·
GAP-22 observability tools (Kibana/APM/Grafana) are internal-only — deep-linking needs a BFF reverse-proxy; internal URLs
never exposed to the browser.

**Verified (container, admin session):** all 10 routes 200; dashboard + payments render real data; RBAC customer→403 /
unauth→307; **zero regression**; 289 MB, healthy, non-root.

## 13g. Phase 7 — DEVOPS Portal Completion (operational handbook)

**Sections (admin + platform_staff):** architecture (boundaries · request/event flow · checkout saga) · service
catalog (18 services) · API Explorer (per-service base/endpoint count + server-side OpenAPI proxy) · ops endpoints
(5-endpoint contract) · infrastructure (9 datastores + Kafka/RabbitMQ/NATS/Temporal) · observability (traces/logs/
metrics/dashboards/alerting) · local-dev (startup order + steps) · runbooks (9: missing-traces, unhealthy, kafka,
rabbitmq, database, temporal, gateway, codegen, docker) · documentation viewer (renders in-repo markdown via
react-markdown with a TOC + section filter).

**Architecture notes:** content authored statically from the spec into `content/devops/handbook.ts` (no live internal
URLs). The **OpenAPI proxy** `/api/devops/openapi/[svc]` is a Node route that role-guards (admin/platform_staff via the
encrypted session, since it's outside the middleware matcher) then fetches the service's openapi.json server-side from
`SPEC_HOST:port` — host:port never reaches the browser. In-repo docs (FRONTEND_ARCHITECTURE.md, COMMAND.md, README.md,
docs/adr/) are COPYed into the standalone image and read at runtime; `.dockerignore` updated to include them.

**Verified (container):** all 9 sections + proxy compile; docs present in image; RBAC customer→403 / unauth→307 /
proxy-unauth→401; **zero regression**; 292 MB, healthy, non-root. Live admin-session content render deferred this window
(admin OTP rate-limited) — sections are static and rendered under the same gate in Phase 6.

## 13h. Phase 8 — Observability + Hardening (verified)

**Security headers (next.config.ts, all routes):** CSP `default-src 'self'` (script/style allow 'unsafe-inline' — Next App
Router inlines hydration without nonces; nonce-CSP is a documented follow-up), `X-Frame-Options: DENY`,
`X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`, `Permissions-Policy` (camera/mic/geo/
payment off), `poweredByHeader: false`. connect-src auto-allows the RUM origin when configured.
**Resilience:** root + route error boundaries (`app/global-error.tsx`, `app/error.tsx`); TanStack Query retry policy (skip
4xx, backoff transient/network ×2, mutations no-retry); networkMode online (offline pause/resume); authedFetch 401→refresh→retry.
**Trace correlation:** Browser → BFF → Gateway → Service via traceparent + x-request-id (verified echoed). RUM user context
set on login / cleared on logout. **Security model:** access token in memory, refresh in encrypted httpOnly SameSite cookie,
CSRF same-origin check on cookie mutations, server-only gateway/internal URLs. **Dependency audit:** 1 moderate (transitive
`next>postcss`, no high/critical). **a11y/i18n:** semantic HTML + ARIA labels + focus-visible rings + bn/en (pickLocale +
toggle) + dark mode tokens (code-reviewed; a formal axe/Lighthouse run is a follow-up). **Docker:** non-root `nextjs`,
healthcheck (node fetch /health), cold-start <1s, 292 MB, healthy.

## 13i. Gap remediation (frontend-only, no backend changes)

Per the directive to fix gaps in the frontend without touching backend services, the **frontend-fixable** gaps were
addressed; the rest are genuinely backend/gateway-blocked and remain honest blocked states (the "never bypass the gateway /
never mock" rules forbid faking them).

**Fixed frontend-only (verified):**
- **GAP-2** search filters → search page over-fetches (size 100, the backend cap) and a client facet sidebar filters
  **price / rating / in-stock** over that window, labeled "top N". Category stays a server param (SSR `<Link>`, no
  `useSearchParams` so the grid SSRs — verified 20 SSR cards). Brand/seller aren't in the search payload → still backend.
- **GAP-4** guest cart → client-side cart (`stores/guest-cart.ts`, Zustand+localStorage; the in-memory rule was for tokens).
  Guests add/edit/remove; on login `mergeGuestCart()` replays items into `cart/me` and clears. Verified: guest cart branch renders.
- **GAP-8** shipment tracking → 17-shipping is customer-reachable by sub-order id (verified 404-not-gated). Order detail now
  fetches `shipping/shipments/by-order/{sub_order_id}` per sub-order and shows status, degrading gracefully when none exists.

**Production-grade resilience (no dead-ends) — every gap wrapped in a complete UX:**
- **GAP-5** product images → `components/product-image.tsx`: deterministic branded placeholder (colour from id + initial)
  across cards, detail, cart, wishlist — the UI never looks broken. Cards also carry `?shop=` (helps GAP-6).
- **GAP-1** seller → seller dashboard with **live connection diagnostics** (catalog/coupon reachable, shop/media not),
  **shop-status card**, **publish-prerequisites checklist**, disabled publish + remediation. No empty seller pages.
- **GAP-9** notifications → polling + **manual Refresh + last-synced timestamp + notification-preferences editor**
  (`/notification/preferences` is reachable).
- **GAP-13** admin orders → **manual order lookup-by-id** form (the only reachable order read) beside the aggregate chart.
- **GAP-15/16** media → **local upload-queue** (object-URL previews, draft management, explicitly blocked publish — nothing
  uploaded, no internal URL).
- All blocked states are **RemediationCard**s (why · dependency owner · recommended backend fix · what-still-works), not bare panels.

**Not frontend-fixable (require backend/gateway changes the directive forbids):** GAP-1 (gateway `seller/*`≠service `shop/*`;
can't bypass the gateway), GAP-3 (backend gates reviews/recs), GAP-5 (no media refs in product payload), GAP-6 (`?shop`
covers the real flow; lookup-by-product can't pick the right shop), GAP-10 (`/review/reviews` has no params + can't prove
caller-scoping — left honest), GAP-13 (no order-list API), GAP-15/16 (media list 404 + presign→internal MinIO; a perfect
upload proxy still can't be read back or attached → no user value), GAP-17/18/19/20/21/22. These stay as documented blocked
states. **The majority of gaps are backend-unreachable and cannot be closed frontend-only.**

## 14. Frontend directory structure (item 7) — `/home/jakir/Desktop/clone/frontend/`

```
frontend/
├─ app/            App Router routes + layouts + (bff) Route Handlers + middleware (guards). OWNER: routing/SSR/BFF
│   ├─ (marketplace)/ (account)/ (seller)/ (admin)/ devops/   route groups per area
│   └─ (bff)/api/…   server-only proxy handlers (browser→BFF→gateway)
├─ components/      Reusable presentational + shadcn primitives (ui/). OWNER: design system. No data fetching.
├─ features/        Feature modules (cart, checkout, search, orders, wallet, devops…): components+hooks+logic per domain. OWNER: feature teams
├─ lib/             Cross-cutting utils (formatMoney paisa, i18n, dates, cn, fetch wrappers, auth helpers). OWNER: platform
├─ services/        Typed API access layer wrapping generated clients + BFF calls (one module per backend service). OWNER: integration
├─ generated/       openapi-typescript output + pinned raw specs + MANIFEST. READ-ONLY (regenerate). OWNER: codegen
├─ stores/          Zustand stores (cart, ui, session). OWNER: state. Client-only.
├─ hooks/           Shared React hooks (useAuth, useLocale, useMediaQuery, TanStack Query wrappers). OWNER: platform
├─ types/           Hand-written shared TS types (not from OpenAPI). OWNER: platform
├─ styles/          Tailwind config + globals + theme tokens. OWNER: design system
├─ public/          Static assets (icons, fonts, manifest). OWNER: design system
├─ content/devops/  DEVOPS static config (services.ts, infra.ts, runbooks/*.md, docs-index.json). OWNER: devops
└─ scripts/         Local dev scripts (fetch-specs.mjs for codegen). OWNER: platform
```

---

## 15. `[VERIFY]` / `[GAP]` resolution register (item 5)

| ID | Missing backend capability | Affected frontend screens | Required API change | Severity | Recommended owner |
| --- | --- | --- | --- | --- | --- |
| GAP-1 | Public seller-storefront read route (e.g. `GET /api/v1/seller/shops/{handle}` public, or via search) unconfirmed | `/store/[handle]` (seller storefront) | confirm/add public shop-by-handle endpoint at gateway | **High** | 03-seller team |
| GAP-2 | Seller order **status-transition** endpoint (`PATCH /api/v1/order/orders/{id}/status`) not found in spec scope | Seller → Orders (fulfill/ship/cancel) | confirm/expose shopkeeper transition endpoint | **High** | 13-order team |
| GAP-3 | WebSocket pass-through for `14-notification` realtime inbox is an open gateway item | Notification inbox realtime | confirm gateway WS proxy or document polling fallback | **Medium** | 15-gateway + 14-notification |
| GAP-4 | Media presigned **download** endpoint (`GET /api/v1/media/{id}/download`) not found (only signed-url/presign-upload confirmed) | Product gallery, seller media | confirm download/signed-read endpoint | **Medium** | 12-media team |
| GAP-5 | Admin surfaces thin: user mgmt beyond auth/admin, seller approval views, payments admin reads | Admin → Users/Sellers/Payments | enumerate admin read/mutation endpoints | **Medium** | 01-auth/03-seller/09-payment |
| GAP-6 | Customer "my reviews" list endpoint unconfirmed | `/account/reviews` | confirm `GET /api/v1/review/me` or filter | **Low** | 08-review team |
| RES-1 | ~~Gateway aggregates specs?~~ **Resolved: NO (404)** — build-time collection (§8) | codegen, DEVOPS explorer | none (handled client-side) | — | resolved |
| RES-2 | ~~traceparent CORS?~~ **Resolved: BFF injection** (§12) | observability | optional gateway CORS later | — | resolved |
| ASM-1 | Service **owners**, Kibana/APM **URLs** not in repo | DEVOPS catalog/observability | provide as config | **Low** | platform |

---

## 16. Risk register

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| Per-service ports not reachable from `13.204.65.180` at build time (codegen fetch) | Med | High (no types) | verify SG/VPC reachability in readiness; fallback = copy specs manually to `generated/openapi/raw/` |
| Backend gaps (GAP-1/2) block seller storefront + fulfillment | Med | High | triage with backend owners before Seller phase; stub screens behind flags |
| Spec drift without CI guard | Med | Med | manual `pnpm gen:api` + `git diff` review discipline; MANIFEST version pinning |
| Trace segments (RUM↔BFF) not linked | Med | Med | BFF continues RUM `traceparent`; validate in APM Service Map during hardening |
| CORS misconfig if any direct browser→gateway call slips in | Low | Med | enforce "browser→BFF only" lint/review; gateway URL server-only |
| Token leakage (XSS) | Low | High | access token in memory only; httpOnly refresh; strict CSP |
| Bengali rendering/perf on low-end mobile | Med | Med | font subsetting, `next/font`, bundle budgets |
| Single dev box (2 vCPU) build/serve contention | Med | Low | build then serve standalone; consider separate build step |

---

## 17. Implementation readiness checklist

| # | Item | Status |
| --- | --- | --- |
| 1 | `/home/jakir/Desktop/clone/frontend/` created | ✅ done |
| 2 | Gateway = sole edge; per-service specs NOT proxied (404) | ✅ verified |
| 3 | Role model (5) + JWT claims + token lifetimes documented | ✅ |
| 4 | Error envelope + paisa + bn/en conventions captured | ✅ |
| 5 | OpenAPI workflow (tool, source, output, regen, versioning) defined | ✅ |
| 6 | Observability decision (BFF trace injection) made | ✅ |
| 7 | DEVOPS portal spec (catalog schema, proxy, RBAC, docs search) defined | ✅ |
| 8 | Deployment (Node runtime, render-per-route, env, topology) defined | ✅ |
| 9 | Directory structure + ownership defined | ✅ |
| 10 | `[VERIFY]`/`[GAP]` register triaged | ✅ |
| 11 | Per-service ports reachable from `13.204.65.180` for build-time codegen | ⬜ **verify before Phase 1** |
| 12 | Gateway `CORS_ALLOWLIST` includes dev frontend origin (only needed if any direct call; BFF avoids it) | ⬜ confirm/N/A |
| 13 | Node 22 + pnpm installed on `13.204.65.180` | ⬜ Phase 1 step |
| 14 | `.env.example` schema agreed (server-only vs NEXT_PUBLIC) | ⬜ Phase 1 step |
| 15 | GAP-1/GAP-2 owners engaged (unblocks Seller phase) | ⬜ track |

**Status: READY for Phase 1 (Foundation)** — blockers #11–#14 are Phase-1 setup steps, not architecture gaps; #15 only blocks the Seller phase.

---

## 18. Phased implementation roadmap (no CI/CD; manual deploy on 13.204.65.180)

| Phase | Scope | Exit criteria |
| --- | --- | --- |
| **Foundation** | install Node/pnpm; scaffold Next.js+TS+Tailwind+shadcn in `/frontend`; `pnpm gen:api` codegen (verify port reachability); BFF proxy + `GATEWAY_URL`; theme/i18n; CSP; `.env.example` | typed client builds; `/` renders via BFF→gateway |
| **Authentication** | OTP login/signup/verify/refresh/logout; cookie+memory tokens; guard middleware; role decode | login→authed call→refresh end-to-end |
| **Marketplace** | Home(BFF), category, search+facets, product detail, storefront, cart, checkout saga (Idempotency-Key, 409) | place a COD order via the gateway |
| **Customer portal** | dashboard, orders+tracking, wallet, addresses(BD geo), reviews, wishlist, notifications | customer self-serve complete |
| **Seller portal** | products/inventory, seller orders, coupons, media presign, analytics (needs GAP-1/2) | list product + fulfill order |
| **Admin portal** | users, sellers, payments(read), reports, risk, system-health | admin oversight reads |
| **DEVOPS portal** | catalog, api-explorer(proxied), ops grid, infra inventory, observability links, runbooks, markdown viewer+search | live ops status for 18 services |
| **Observability & hardening** | RUM + BFF traceparent, CWV budgets, WCAG AA audit, CSP tighten, manual load test | traces correlate; AA passes; CSP enforced |

> **No code generated. Awaiting "go" to begin Phase 1 (Foundation) in `/home/jakir/Desktop/clone/frontend/`.**
