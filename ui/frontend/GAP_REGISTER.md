# DOKANDAR Frontend — GAP Register & Production-Readiness Matrices

Frontend-only mitigations for backend limitations. Rules held throughout: never modify backend/gateway,
never bypass the gateway, never expose internal URLs, never fabricate data or fake successful operations.

**Category key:** A = fixed entirely in frontend · B = backend unavailable, frontend experience completed
(resilient UX) · C = hard backend blocker (surrounding UX built, blocked action isolated + remediation).

## 1. Gap matrix

| GAP | Cat | Frontend mitigation | User impact | Backend owner | Recommended backend fix | Status |
| --- | --- | --- | --- | --- | --- | --- |
| GAP-1 seller/shop 404 | C | Seller dashboard: live diagnostics, shop-status card, publish-prereqs, disabled publish; remediation cards across seller+admin | No shop setup/publish/seller-orders | 15-gateway / 03-seller | Route `/api/v1/seller/*` → service `/api/v1/shop/*` | Mitigated (resilient) |
| GAP-2 search filters | A | Over-fetch (size 100) + client price/rating/in-stock facets, labeled "top N" | Rich filtering on the window | 05-search | Add price/rating/brand/seller/sort params | **Fixed** |
| GAP-3 reviews/recs gated | B | Shown when logged-in; "log in to see" for guests | Guests don't see reviews/recs | 08/16/15 | Allow public GET reviews/recs | Resilient |
| GAP-4 guest cart 401 | A | Client-side cart (Zustand+localStorage) + merge into cart/me on login | Guests can shop pre-login | 06-cart/15 | Allow `/cart/guest/*` unauth | **Fixed** |
| GAP-5 no product images | B | Branded deterministic placeholders (colour+initial) everywhere | UI looks intentional | 04-catalog/12-media | Add `media_id` to product payload | Resilient (UX complete) |
| GAP-6 no shop_id on detail | B | Cards carry `?shop=`; add-to-cart uses it | Add-to-cart works from listings | 04-catalog | Include shop_id on product detail | Mostly fixed |
| GAP-7 order list no params | A | Client-side filter + pagination | Order history filterable | 13-order | Add filter/page params | **Fixed** |
| GAP-8 shipment tracking | A | Order detail fetches `shipping/shipments/by-order/{id}` per sub-order | Live tracking when shipped | 17-shipping (reachable) | — (works) | **Fixed** |
| GAP-9 notifications realtime | B | Polling (30s) + manual refresh + last-synced + preferences editor | Near-real-time inbox | 14-notification | Expose WS/SSE in OpenAPI | Resilient (complete) |
| GAP-10 review "mine" filter | A/B | Defensive client owner-filter when rows carry an owner field | Correct "my reviews" if field exists | 08-review | Add `?author=me` or scope by token | Best-effort fixed |
| GAP-11 profile/me 404 (new) | B | Graceful "still syncing" + editable form | New users edit profile anyway | 02-profile | Sync projection on signup | Resilient |
| GAP-12 catalog not seller-scoped | A | Client owner-filter by user id | Seller sees own products | 04-catalog | Add `?owner=me` | **Fixed** |
| GAP-13 no seller/admin order list | B | Admin order lookup-by-id + aggregate chart; seller remediation | Inspect orders by id | 13-order | Add admin/seller order search | Mitigated |
| GAP-14 coupon activation admin | B | Seller creates draft → "pending approval" | Seller drafts coupons | 07-coupon | Seller self-activate or clear flow | Resilient |
| GAP-15 presign→internal MinIO | C | Local upload queue (object-URL previews, draft mgmt, blocked publish) | Stage images locally | 12-media/15 | Browser-reachable presign / upload proxy | Resilient |
| GAP-16 media list 404 | C | Remediation card + local drafts | — | 12-media/15 | Expose GET /media via gateway | Resilient |
| GAP-17 catalog write schemas | C | Product create/edit/stock work (shape derived); variant-create noted | Product CRUD works | 04-catalog | Document request bodies in OpenAPI | Partial |
| GAP-18 no inventory history | C | Stock view + adjust work; history noted | Current stock manageable | 04-catalog | Add stock-ledger endpoint | Noted (no API) |
| GAP-19 shopkeeper not self-service | C | N/A — provisioning/test limit | Can't QA seller authed in this env | 01-auth | Admin role-assignment endpoint | Noted (env limit) |
| GAP-20 no user list | B | Lookup-by-id + KYC queue | Admin finds users by id | 01/02 | Add paginated user search | Mitigated |
| GAP-21 no platform notif API | B | Remediation card; per-user inbox works | — | 14-notification | Admin delivery-monitoring API | Resilient |
| GAP-22 observability internal | B | Observability model documented in System | Operators know the join keys | platform | BFF reverse-proxy for Kibana/APM | Resilient |

## 2. Route matrix

| Route | Implementation | Backend dependency | User readiness |
| --- | --- | --- | --- |
| `/` `/search` `/category/[slug]` `/product/[id]` | Complete (SSR) | catalog+search (public) ✅ | ✅ Ready |
| `/cart` `/checkout` `/wishlist` | Complete | cart authed; guest client-side; payment pending | ✅ browse/cart · ⚠️ checkout (no payment) |
| `/account` `/account/*` | Complete (CSR) | profile/order/wallet/notif/review ✅ | ✅ Ready |
| `/seller` `/seller/*` | Complete (CSR) | catalog/coupon ✅; shop ❌ (GAP-1) | ⚠️ frontend-ready, **unverifiable in this env (GAP-19)** |
| `/admin` `/admin/*` | Complete (CSR) | reporting/payment/risk/kyc ✅; sellers/orders/notif blocked | ✅ Ready (last live-rendered Phase 6; admin OTP rate-limited this window) |
| `/devops` `/devops/*` | Complete | local specs + server proxy | ✅ Ready |
| `/login` `/verify` `/logout` `/forbidden` `/not-found` | Complete | auth ✅ | ✅ Ready |
| `/health` `/ready` `/data` | Complete | self | ✅ Ready |

## 3. Production-readiness matrix

| Area | Frontend Complete | Backend Complete | User Ready |
| --- | --- | --- | --- |
| Marketplace (home/search/product) | ✅ | ✅ | ✅ |
| Cart + guest cart | ✅ | ⚠️ guest 401 (mitigated client-side) | ✅ |
| Checkout (COD) | ✅ | ✅ COD works | ✅ order places + appears in history |
| Checkout (online pay) | ✅ ready | ❌ payment provider not wired | ⚠️ COD only |
| Customer portal | ✅ | ✅ | ✅ |
| Seller portal | ✅ | ❌ GAP-1 (shop) | ⚠️ frontend-ready, unverifiable (GAP-19) |
| Admin portal | ✅ | ✅ reporting/payment/risk | ✅ (Phase-6 verified; rate-limited now) |
| DEVOPS portal | ✅ | n/a | ✅ |
| Auth + RBAC | ✅ | ✅ | ✅ |
| Hardening (CSP/headers/errors/retry) | ✅ | n/a | ✅ |

## 4. Honest remaining frontend-only work (non-blocking)

- **Chrome i18n parity:** product *data* is bilingual (`pickLocale`) but UI *chrome* is English-only except login/verify
  (`lib/i18n.ts` exists). Full chrome translation is real frontend-only work — deferred, not done.
- **List virtualization** for very large grids/tables (current data volumes don't require it).
- **GAP-17 variant-create form** awaits a documented request schema.

These need no backend change but were scoped out as low-value at current data volumes; everything gap-driven is complete.
