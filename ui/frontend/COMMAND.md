# DOKANDAR Frontend — COMMAND.md

Copy-paste operational commands. Host: `13.204.65.180` (Node 22 via nvm + Docker). Edge: Next.js BFF →
API Gateway `172.31.14.241:10015` (app-server private VPC IP) → 18 services. **No CI/CD.**

---

## Development

```bash
# from the repo root: ~/frontend (server) or /home/jakir/Desktop/clone/frontend (dev)
cp env/.env.dev .env.local        # local env (GATEWAY_URL etc.)
pnpm install                      # native builds (sharp/unrs) pre-approved in pnpm-workspace.yaml
pnpm dev                          # http://localhost:3000  (Turbopack)
pnpm lint                         # ESLint
pnpm build                        # production build (output: standalone)
pnpm start                        # serve the build on :3000
```

## OpenAPI

```bash
pnpm gen:api                                      # fetch 18 specs + generate typed clients into generated/
SPEC_HOST=172.31.14.241 pnpm gen:api              # override the app host (private VPC IP)
cat generated/openapi/MANIFEST.json | jq .        # verify the manifest (svc -> version)
ls generated/openapi/*.ts | wc -l                 # expect 19 typed clients
git diff --stat generated/                        # review drift before committing
```

## Docker

```bash
# build (stamp /data metadata via build args)
docker build -t dokandar-frontend \
  --build-arg CODE_VERSION=$(cat CODE_VERSION) \
  --build-arg BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --build-arg GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo nogit) .

# run (server env via --env-file; container is non-root, port 3000)
docker run -d --name dokandar_frontend_dev -p 3000:3000 --env-file env/.env.dev \
  --restart unless-stopped dokandar-frontend

docker logs -f dokandar_frontend_dev              # logs
docker exec -it dokandar_frontend_dev sh          # shell access (runs as user nextjs)
docker stop dokandar_frontend_dev && docker rm dokandar_frontend_dev   # stop + remove
docker image inspect dokandar-frontend --format 'size={{.Size}}'       # image size
```

## Observability

```bash
# RUM is active only when NEXT_PUBLIC_RUM_SERVER_URL is set at BUILD time (client var is baked at build).
curl -s http://127.0.0.1:3000/data | jq .observability      # rum_enabled + trace propagation mode
# trace correlation: the BFF injects W3C traceparent + x-request-id on every gateway call —
curl -s -D - -o /dev/null http://127.0.0.1:3000/api/gw/search/products | grep -i x-request-id
# (with RUM configured, the browser trace continues through BFF → gateway → service in Elastic APM)
```

## Operations

```bash
curl -s http://127.0.0.1:3000/health | jq .        # liveness (always 200 if up)
curl -s http://127.0.0.1:3000/ready  | jq .        # readiness: gateway + env + manifest (503 if any down)
curl -s http://127.0.0.1:3000/data   | jq .        # operational metadata (gateway_url masked)
# smoke: BFF proxy returns real backend JSON, DEVOPS RBAC enforced
curl -s -o /dev/null -w "search=%{http_code}\n" http://127.0.0.1:3000/api/gw/search/products
curl -s -o /dev/null -w "devops_noauth=%{http_code}\n" http://127.0.0.1:3000/devops          # 307
curl -s -o /dev/null -w "devops_admin=%{http_code}\n" --cookie dokandar_role=admin http://127.0.0.1:3000/devops  # 200
```

## Authentication (Phase 2)

```bash
# setup: SESSION_COOKIE_SECRET must be set (encrypts the httpOnly session cookie). Already in env/.env.dev.
# the BFF owns auth: browser → /api/auth/* (cookie) and /api/gw/auth/* (public proxy) → gateway → 01-auth.

# --- login test (OTP) ---  (00-support gives the dev OTP; the app never calls support)
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:3000/api/gw/auth/login/request \
  -H 'content-type: application/json' -d '{"phone":"01700000000"}'                       # 202
CODE=$(curl -s "http://172.31.14.241:10099/otp/latest?phone=01700000000&purpose=login" | jq -r .code)
curl -s -c /tmp/cj.txt -X POST http://127.0.0.1:3000/api/auth/verify \
  -H 'content-type: application/json' -d "{\"mode\":\"login\",\"phone\":\"01700000000\",\"code\":\"$CODE\"}" | jq .
grep dokandar_session /tmp/cj.txt && echo "httpOnly session cookie set (encrypted; no refresh token in body)"

# --- token refresh test (rotates the cookie) ---
curl -s -b /tmp/cj.txt -c /tmp/cj.txt -X POST http://127.0.0.1:3000/api/auth/refresh | jq '.access_token|length, .expires_in'

# --- session bootstrap (cold load / new tab) ---
curl -s -b /tmp/cj.txt http://127.0.0.1:3000/api/auth/session | jq .user.role

# --- logout test (revokes refresh token everywhere + clears cookie) ---
curl -s -b /tmp/cj.txt -c /tmp/cj.txt -X POST http://127.0.0.1:3000/api/auth/logout | jq .
curl -s -b /tmp/cj.txt -o /dev/null -w 'after-logout refresh=%{http_code}\n' -X POST http://127.0.0.1:3000/api/auth/refresh  # 401

# --- RBAC test (server-enforced via encrypted session) ---
curl -s -o /dev/null -w 'devops no-session=%{http_code}\n' http://127.0.0.1:3000/devops            # 307 → /login
# (with an admin session cookie, /devops = 200; a customer session → /forbidden)
```

## Marketplace (Phase 3)

```bash
# SSR pages fetch PUBLIC catalog/search server-side (BFF not needed for guests); authed cart/reviews/recs via BFF.
H=http://127.0.0.1:3000
curl -s -o /dev/null -w 'home=%{http_code}\n'   $H/                              # homepage (categories+trending+featured)
curl -s -o /dev/null -w 'search=%{http_code}\n' "$H/search?q=&size=6"            # search (q+category+page/size)
PID=$(curl -s "$H/api/gw/search/products?size=1" | jq -r '.items[0].product_id')
curl -s -o /dev/null -w 'product=%{http_code}\n' "$H/product/$PID"               # product detail
curl -s -o /dev/null -w 'cart=%{http_code}\n'   $H/cart                          # cart (guest → login prompt)
# smoke: homepage renders real data
curl -s $H/ | grep -oc 'href="/product/'        # >0 product cards
curl -s $H/ | grep -oE 'Shop by category|Featured products'                     # SSR sections present
```

**Known gaps (backend):** GAP-1 seller storefront (gateway prefix `seller/*` ≠ service `shop/*`, 404) ·
GAP-2 search filters limited to `category_id` (no price/rating/brand/seller/sort) · GAP-3 reviews+recs
Bearer-gated (authed only) · GAP-4 guest cart 401 (cart requires login) · GAP-5 product images not in
public catalog/search (placeholder) · GAP-6 product detail lacks shop_id for cart (passed via `?shop=`).

## Customer Portal (Phase 4)

```bash
H=http://127.0.0.1:3000
# unauth account routes redirect to /login (307); authed → 200. All data via the BFF (Bearer).
for p in /account /account/orders /account/wallet /account/addresses /account/notifications /account/profile /account/reviews; do
  printf '%-26s %s\n' "$p" "$(curl -s -o /dev/null -w '%{http_code}' $H$p)"; done   # all 307 unauth
# authed account data through the BFF (use a logged-in session cookie / Bearer):
for e in profile/me order/orders/me wallet/me 'notification/inbox?size=5' cart/wishlist profile/me/addresses profile/geo/divisions; do
  printf '%-26s %s\n' "$e" "$(curl -s -o /dev/null -w '%{http_code}' "$H/api/gw/$e" -H "authorization: Bearer $AT")"; done
```

**Phase 4 gaps:** GAP-7 order list has no backend filter/page params (client-side) · GAP-8 shipment
tracking (17-shipping) not in customer gateway set · GAP-9 notifications realtime is NATS not REST →
**polling** (30s) · GAP-10 review-list "mine" filter unverified · GAP-11 `profile/me` 404 until the Kafka
profile projection lands for new users (handled). Wallet top-up exists but needs the payment phase.

## Seller Portal (Phase 5)

```bash
H=http://127.0.0.1:3000
# RBAC: /seller is gated to shopkeeper + shop_staff. customer → 403 /forbidden, unauth → 307 /login.
curl -s -b CUSTOMER_COOKIE $H/seller | grep -oiE 'forbidden|403'     # customer is rewritten to /forbidden
curl -s -o /dev/null -w '%{http_code}\n' $H/seller                   # 307 (unauth)
# data path (privileged token — shopkeeper can't be self-provisioned, GAP-19):
CID=$(curl -s $H/api/gw/catalog/categories/tree | jq -r '.tree[0].category_id')
curl -s -o /dev/null -w 'create=%{http_code}\n' -X POST $H/api/gw/catalog/products -H "authorization: Bearer $AT" \
  -H 'content-type: application/json' -d "{\"name_en\":\"P\",\"name_bn\":\"প\",\"category_id\":\"$CID\",\"list_price_minor\":20000}"  # 201 draft
curl -s -o /dev/null -w 'coupons=%{http_code}\n' $H/api/gw/coupon/coupons/me -H "authorization: Bearer $AT"                          # 200
```

**Phase 5 gaps (seller is heavily backend-gated):** GAP-1 seller/shop service unreachable (gateway `seller/*`
≠ service `shop/*`, 404) → no shop setup/storefront/staff, cascades to product-publish + coupon `shopId` ·
GAP-12 catalog list not seller-scoped (owner-filtered client-side; draft visibility varies) · GAP-13 no seller
order list (only buyer's `/orders/me`) · GAP-14 coupon activation is admin `approve` · GAP-15 media presign
points at internal MinIO host · GAP-16 media list `/media` 404 · GAP-17 catalog write request schemas
undocumented in OpenAPI · GAP-18 no inventory-history API · GAP-19 shopkeeper not self-serviceable at signup
(`role_not_self_serviceable`) + no admin role-assign endpoint → seller-authed flows unexercisable here.
**Functional:** product create/edit/stock (draft) + coupon listing. **Blocked (honest empty states):**
orders, media, analytics, shop, coupon-create.

## Admin Portal (Phase 6)

```bash
H=http://127.0.0.1:3000   # /admin gated to admin + platform_staff; others → 403, unauth → 307
for p in /admin /admin/users /admin/payments /admin/reports /admin/risk /admin/wallets /admin/system; do
  printf '%-18s %s\n' "$p" "$(curl -s -b ADMIN_COOKIE -o /dev/null -w '%{http_code}' $H$p)"; done   # 200 admin
curl -s -b CUSTOMER_COOKIE $H/admin | grep -oiE 'forbidden|403'    # customer rewritten to /forbidden
# data: dashboard = reporting/platform-kpis + orders-by-period + payment-mix (real GMV/orders/AOV/take-rate)
```

**Functional:** dashboard (platform KPIs + orders bar chart + payment mix), payments (payouts/commission-
rates/COD ledger), reports (KPIs/payment-mix/payouts-history), risk (rules list + create), users (KYC
queue approve/reject + per-user lookup), wallets (per-user balance), system (ops + service catalog +
observability model). **Blocked (honest states):** sellers (GAP-1), per-order monitoring (GAP-13),
admin notifications (GAP-21). **Phase 6 gaps:** GAP-20 no user-list API (lookup by id) · GAP-21 no
platform-wide notification API · GAP-22 observability tools internal-only (deep-link needs a BFF proxy).

## DEVOPS Portal (Phase 7)

```bash
H=http://127.0.0.1:3000   # /devops gated to admin + platform_staff
# 9 sections (static handbook content): architecture, catalog, api-explorer, ops-endpoints,
# infrastructure, observability, local-dev, runbooks, docs
for s in architecture catalog api-explorer infrastructure observability runbooks docs; do
  printf '%-16s %s\n' "$s" "$(curl -s -b ADMIN_COOKIE -o /dev/null -w '%{http_code}' $H/devops/$s)"; done
# documentation viewer renders in-repo markdown (copied into the image): FRONTEND_ARCHITECTURE.md, COMMAND.md, README.md, docs/adr/*
curl -s -b ADMIN_COOKIE "$H/devops/docs?doc=architecture"
# OpenAPI explorer — server-side proxy (admin only, never exposes host:port):
curl -s -b ADMIN_COOKIE $H/api/devops/openapi/01-auth | jq '.info.title'   # 200; unauth → 401
```

Service catalog = 18 services (name/language/framework/ports/datastores/owner). API stats: 173 business
endpoints across 19 specs. Runbooks: 9 (missing-traces, unhealthy-service, kafka, rabbitmq, database,
temporal, gateway, codegen, docker). Note: the doc viewer renders **in-repo** docs (overview/*.md live in
a separate spec repo). Internal observability tools are not browser-reachable (GAP-22).

## Gap resilience (production-grade UX)

Every backend gap has a frontend response — fixed (Category A), resilient blocked state (B), or isolated
action + remediation (C). Full matrix + per-route readiness + production-readiness scores:
**[GAP_REGISTER.md](GAP_REGISTER.md)**.

```bash
H=http://127.0.0.1:3000
# Category-A fixes (verifiable):
curl -s $H/search | grep -oE 'Min rating|In stock only'                     # GAP-2 facets
curl -s $H/cart | grep -oE 'Your cart is empty'                             # GAP-4 guest cart branch
# add-to-wishlist (live): POST cart/wishlist/items {product_id} → 201, GET cart/wishlist shows it
curl -s $H/search | grep -oE 'bg-gradient-to-br from-[a-z]+-400' | head -1  # GAP-5 branded placeholder
# Category-B/C: seller dashboard diagnostics, remediation cards, local media queue — no dead-ends.
```

## Troubleshooting

| Symptom | Check / fix |
| --- | --- |
| **Codegen fails** (`pnpm gen:api`) | `curl http://$SPEC_HOST:10005/openapi.json` reachable? Wrong `SPEC_HOST`? App service down? Re-run; raw specs persist in `generated/openapi/raw/`. |
| **Gateway connectivity** (`/ready` 503, home "unreachable") | `curl http://172.31.14.241:10015/ready`. Wrong `GATEWAY_URL`/IP (public vs private VPC)? SG blocks the port? Restart with corrected `env/.env.dev`. |
| **Docker build fails** | native build? ensure `pnpm-workspace.yaml allowBuilds: {sharp,unrs-resolver: true}`. Standalone missing module at runtime (pnpm symlink tracing)? add `.npmrc` `node-linker=hoisted` and rebuild. |
| **Container unhealthy** | `docker logs dokandar_frontend_dev`; `docker exec … wget -qO- http://127.0.0.1:3000/health`. |
| **Missing traces** | RUM only ships when `NEXT_PUBLIC_RUM_SERVER_URL` is set **at build**. Confirm BFF injects traceparent: `curl -D-` shows `x-request-id`. Check APM `service.name=dokandar-web`. |
| **Login/verify 401** | OTP expired (5 min) / wrong, or rate-limited (5/hr → `redis DEL otp_rate:<phone>`). Cross-origin POST → CSRF 403 (check the `Origin` header). |
| **Session lost on reload** | `SESSION_COOKIE_SECRET` missing/changed (invalidates cookies). In dev over http the cookie is non-Secure (needs `APP_ENV=dev`); in prod it is Secure (https only). |
| **RBAC always redirects to /login** | encrypted session cookie absent or undecodable — confirm `SESSION_COOKIE_SECRET` is identical to the value used when the session was issued. |
