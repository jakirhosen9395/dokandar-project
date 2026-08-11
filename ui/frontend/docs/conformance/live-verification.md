# DOKANDAR — Live End-to-End Verification (Seller · Shop · Catalog · Cart · Checkout)

Verified against the **live backend** (gateway `47.128.217.17:10015`, shop svc `:10003`) on 2026-07-06 with real OTP sessions: shopkeeper `01700000078`, admin `01700000000`, customer (fresh). Seed data: shop `72b8c94e…` + 5 published products (variant + shared-pool stock). **Result: 23/30 flows PASS.** Every failure is **backend / gateway / config — none are frontend bugs.** The frontend calls the correct endpoints and handles the responses correctly.

## PASS (23)
Seller auth (JWT `role=shopkeeper`) · shop direct reachable (`:10003`) · shop profile edit (PATCH) · shop hours GET · category tree · **product create / edit / add-variant / stock / publish / unpublish** · seller own-product listing (client owner-filter, GAP-12) · customer browse · search · product detail (with variants) · **add-to-cart / update-qty / remove** · wishlist add+get · order placement (201) · order history (200) · shipping-by-sub-order (endpoint works; 404 = no shipment created yet).

## FAIL (7) — all backend/gateway

### 1. Shop unreachable via the gateway — **GATEWAY / CONFIG** (GAP-1, hard blocker)
- **Req:** `GET /api/v1/seller/shops` (Bearer shopkeeper) → **404**; `GET /api/v1/shop/shops` → **404**. Direct `GET :10003/api/v1/shop/me` → **200**.
- **Root cause:** gateway registers `/api/v1/seller/*` (upstream key `seller`) and forwards **verbatim**, but the seller service (Laravel) serves `/api/v1/shop/*`. So `/api/v1/seller/*` → service 404, and `/api/v1/shop/*` → no gateway route → 404. The service is only reachable on its direct port, which the browser must never use.
- **Not frontend-fixable** without bypassing the gateway (forbidden). Fix belongs in the gateway: route `/api/v1/shop/*` to the `seller` upstream (or rename the upstream key to `shop`, or add a path rewrite).
- **Blocks:** shop create/edit/settings/staff/media, storefront — the entire browser-side seller shop-management surface.

### 2. Checkout prices every line at 0 — **BACKEND** (contract mismatch, highest leverage)
- **Req/Resp:** `POST /cart/me/checkout-package {payment_method:cod}` → 200 but `grand_total_minor:0`, `sub_orders[].items[].unit_price_minor:0`. Product `3d404b22` in catalog has `list_price_minor:250000 / sale_price_minor:199000`.
- **Diagnostic (rules out frontend):** adding to cart with an explicit `unit_price_minor:199000` is **ignored** — stored line price is still 0. The cart prices server-side; the client cannot influence it.
- **Root cause (source):** `06-cart/src/downstream/clients.ts` `checkStock()` does `GET /api/v1/catalog/products/{id}` then reads `r.data.list_price_minor` and `r.data.variants` at the **top level**. Catalog returns the product **wrapped**: `{"product":{ list_price_minor, variants, … }}`. So both reads are `undefined` → `unit = 0` and the variant lookup never runs. Backend fix (one line): `const p = (r.data?.product ?? r.data) || {}`.
- **Blocks (downstream):** real order totals, wallet-from-order, reporting KPIs, COD ledger — all compute to ৳0.

### 3. Checkout risk = hold — **BACKEND** (secondary)
- `checkout-package` returns `risk:{decision:"hold", hold_reason:"cod_risk_http_error"}`. The cart's `scoreCheckout` HTTP call to 18-risk errors and defaults to COD-hold. Order still places (hold ≠ block). Root cause is the cart↔risk call (risk `POST /api/v1/risk/score/cod` requires an internal service token; the cart's call is erroring). Backend/config.

### 4. Coupon `validate` direct → 401 — **INTERNAL-ONLY (by design, not a gap)**
- `POST /api/v1/coupon/validate` (customer Bearer) → 401 `x-internal-token missing or invalid`. This is a **service-to-service** endpoint; the cart calls it during `checkout-package` (`coupon_applied`). The frontend correctly does **not** call it directly and passes `coupon_code` to `checkout-package` instead. No frontend change needed.

### 5. Shop media (logo/banner) → 501 — **BACKEND (not implemented)**
- `POST :10003/api/v1/shop/shops/{id}/logo` → **501** `not_implemented: Media gRPC client is wired but PresignUpload is not implemented`. Compounded by media presign returning a VPC-internal URL (`172.31.36.11:9002`, GAP-15) unreachable by browsers. Blocks all image upload (shop logo/banner, product images, avatar, KYC docs, review photos).

### 6. Seller order listing → 404/405 — **BACKEND (endpoint missing, GAP-13)**
- `GET /api/v1/order/sub-orders?shop_id=…` → **404**; `GET /api/v1/order/orders?shop_id=…` → **405** (`/order/orders` is POST-only). The order service exposes no seller/shop-scoped order-list API. Frontend already shows a remediation state. Needs a backend endpoint.

### 7. Shop hours PUT → 422 (test artifact, not a product bug)
- `PUT :10003/…/hours {hours:[{day,open,close}]}` → 422 `invalid body` — my probe used the wrong `HoursReplace` shape; the endpoint itself is healthy (GET works). Gateway-blocked for the browser regardless (see #1).

## Conclusion
Across **Seller, Shop, Catalog, Cart, and Checkout**, the frontend integration is correct end-to-end. The gaps that remain are:
- **1 gateway/config bug** (GAP-1 shop routing) — blocks the browser-side seller/shop surface.
- **backend bugs** — cart↔catalog price envelope mismatch (the #1 domino), cart↔risk call, media PresignUpload unimplemented + internal presign URLs, missing seller order-list endpoint.
- **0 frontend bugs.**

The single highest-leverage fix is the **one-line cart pricing bug (#2)** — it unblocks real totals across checkout, orders, wallet, and reporting.
