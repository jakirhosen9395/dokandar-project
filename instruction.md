# DOKANDAR — Complete User & Platform Guide (instruction.md)

DOKANDAR is a full **e-commerce marketplace platform** built for the Bangladesh
market. It lets **customers** discover and buy products, **shopkeepers** open
shops and sell, and **platform administrators** run and govern the whole
marketplace. It is bilingual (**bn / en**), **phone-OTP** based (no passwords),
and **Cash-on-Delivery (COD)** friendly, with digital wallet and online payment
options.

The platform is made of **18 backend microservices** (plus one dev helper) behind
a single **API Gateway**, and one **Next.js web application** (the storefront +
all portals). The browser only ever talks to the web app; the web app's server
(the "BFF") talks to the gateway, and the gateway routes to the services.

> **Where things run (current deployment)**
> - **Web app (frontend):** `http://13.250.60.53:3000`
> - **Backend (API gateway + 18 services):** host `47.128.217.17` (gateway on port `10015`)
> - **Infrastructure (databases, Kafka, etc.):** host `47.129.206.184`
> - Open **`http://13.250.60.53:3000`** in a browser to use the platform.

---

## 1. Who uses DOKANDAR (user types / roles)

| Role | Who they are | What they do |
|------|--------------|--------------|
| **Guest** (not logged in) | Any visitor | Browse the storefront, search, view products, see prices — no account needed |
| **Customer** | A registered shopper | Everything a guest can do, plus cart, checkout, orders, wallet, reviews, notifications, addresses |
| **Shopkeeper** | A seller who owns a shop | Runs the Seller Portal: products, stock, coupons, media, orders, shop settings |
| **Shop staff** | An employee added by a shopkeeper | Helps run a shop (scoped to that shop's operations) |
| **Platform staff** | Internal operations staff | Admin portal (support/ops view) + DevOps portal |
| **Admin** | Platform administrator | Full control: KPIs, payments, payouts, risk rules, KYC approvals, wallets, system |

Roles are assigned at sign-up / by admins and are carried inside a signed **JWT**.
Every page and API is **role-gated**: the wrong role is redirected to `/login`
(if not signed in) or `/forbidden` (if signed in without permission).

---

## 2. Getting an account & signing in

Sign-in is **passwordless** — you authenticate with your **phone number + a
one-time code (OTP)**.

### Sign up (new users)
1. Go to `http://13.250.60.53:3000/login` and switch the form to **Sign up**.
2. Enter your **name** and **phone** (e.g. `01XXXXXXXXX`), then request the code.
3. Enter the 6-digit code → your account is created and you are signed in as a **customer**.

### Log in (existing users)
1. Go to `/login`, enter your **phone**, request the code.
2. Enter the code → you're in. Your session is kept in a secure, encrypted,
   http-only cookie (rotated automatically; the browser never stores the raw token).

### Where does the OTP come from?
This deployment runs in **dev mode with no SMS provider**, so codes are not texted.
Retrieve your code from the dev OTP readback tool:

```
http://47.128.217.17:10099/otp/latest?phone=<YOUR_PHONE>&purpose=login
# use purpose=signup when registering
```

It returns `{"code":"123456", ...}`. Codes expire in **5 minutes** (max 5
requests/hour per phone). In production you would connect an SMS gateway in the
Auth service so users receive the code directly.

> **Note:** *Logging in with an unregistered phone will say "code sent" but no code
> is ever generated* (this is a privacy feature so nobody can probe which numbers
> are registered). If login gives you no code, **sign up first**.

---

## 3. What a CUSTOMER can do (and guests, where noted)

Storefront + customer account. Routes are on `http://13.250.60.53:3000`.

**Browse & discover (guest + customer)**
- **Home (`/`)** — shop-by-category, trending, and featured products.
- **Search (`/search`)** — full-text product search (Bangla/English) with filters
  (category, in-stock, min-rating) and paging.
- **Product detail (`/product/{id}`)** — product info, price, images, reviews.
- **Recommendations** — personalized feed, "similar products", trending.

**Shop & buy (customer)**
- **Cart (`/cart`)** and **Wishlist (`/wishlist`)** — add/remove items, save for later.
- **Checkout (`/checkout`)** — place an order; pay by **Cash on Delivery**,
  **digital wallet**, or an **online provider** (bKash, Nagad, Rocket, SSLCommerz, Stripe).
- **Coupons** — apply discount coupons at checkout.
- **Shipping** — delivery quotes and, after ordering, shipment tracking.

**Manage your account (`/account`)**
- **Profile (`/account/profile`)** — name, language, and personal details.
- **Addresses (`/account/addresses`)** — delivery addresses (Bangladesh divisions/geo).
- **Orders (`/account/orders`)** — order history and status.
- **Wallet (`/account/wallet`)** — balance, top-up, and transaction history.
- **Reviews (`/account/reviews`)** — reviews you've written (rate products, edit within the window, report abuse).
- **Notifications (`/account/notifications`)** — your inbox (order updates, etc.), with channel preferences (email/SMS/push/WhatsApp).

---

## 4. What a SHOPKEEPER / SHOP STAFF can do (Seller Portal)

The **Seller Portal (`/seller`)** is gated to `shopkeeper` and `shop_staff`.

- **Products** — create/edit products (name bn+en, category, price in paisa),
  manage **stock**, publish drafts.
- **Product media** — upload product images (stored via object storage / presigned upload).
- **Coupons** — create and list shop coupons (admin approves activation).
- **Orders** — view orders for the shop (buyer-side order data available now).
- **Shop & storefront** — shop profile, staff assignment, storefront (see gaps below).
- **Analytics** — shop performance views.

> The seller area is intentionally resilient: features that depend on
> not-yet-complete backend endpoints show honest "coming soon / blocked" states
> instead of breaking. See **Known limitations** below.

---

## 5. What ADMIN / PLATFORM STAFF can do (Admin Portal)

The **Admin Portal (`/admin`)** is gated to `admin` and `platform_staff`.

- **Dashboard (`/admin`)** — platform KPIs: GMV, orders, average order value,
  take-rate, orders-by-period chart, and payment-method mix.
- **Payments (`/admin/payments`)** — payouts, commission rates, COD ledger.
- **Reports (`/admin/reports`)** — KPIs, payment mix, payout history.
- **Risk (`/admin/risk`)** — fraud/risk rules: list and create rules that drive
  checkout decisions (allow / review / deny) and COD risk.
- **Users (`/admin/users`)** — **KYC** review queue (approve/reject seller
  identity documents) and per-user lookup.
- **Wallets (`/admin/wallets`)** — per-user wallet balances.
- **System (`/admin/system`)** — operations view, service catalog, observability model.

---

## 6. DevOps Portal (internal)

The **DevOps Portal (`/devops`)**, gated to `admin` + `platform_staff`, is an
in-app handbook for operators:
architecture, service catalog, **API explorer** (browse each service's OpenAPI
spec), ops-endpoints, infrastructure, observability, runbooks, and rendered docs.

---

## 7. The 18 backend services (+ 1 dev helper) — what each one powers

Every service publishes REST on host port `100NN` and (where it has one) gRPC on
`200NN`. Together they provide every facility above.

| # | Service | Tech | Powers (purpose) |
|---|---------|------|------------------|
| 00 | **support** (`:10099`) | Python/FastAPI | **Dev/stage helper only** — reads back OTP codes (since dev has no SMS) and simulates payment webhooks. Not a user-facing service. |
| 01 | **auth** (`:10001`, gRPC `:20001`) | Python/FastAPI | **Authentication & identity** — phone-OTP sign-up/login, issues signed **RS256 JWTs**, defines all roles (customer/shopkeeper/shop_staff/platform_staff/admin), KYC document submission & approval, and the shared service token that lets services trust each other. |
| 02 | **profile** (`:10002`, gRPC `:20002`) | Go | **Customer profiles** — names, languages, **delivery addresses**, and Bangladesh geo (divisions/districts). Keeps profiles in sync from platform events. |
| 03 | **seller / shop** (`:10003`) | PHP/Laravel | **Shops** — shop creation, **shop-staff assignment**, storefront, and shop media for shopkeepers. |
| 04 | **catalog** (`:10004`, gRPC `:20004`) | Java/Spring | **Product catalog** — products (bn/en, price in paisa), categories tree, and **stock**. The source of truth for what's for sale. |
| 05 | **search** (`:10005`) | Rust/Axum | **Product search** — fast full-text search over the catalog with facets (category, price, rating, in-stock). |
| 06 | **cart** (`:10006`) | Node/NestJS | **Shopping cart & wishlist** — items customers intend to buy or save. |
| 07 | **coupon** (`:10007`, gRPC `:20007`) | C#/.NET | **Coupons & discounts** — create, list, validate and apply promo codes; admin approval of activation. |
| 08 | **review** (`:10008`, gRPC `:20008`) | Kotlin/Ktor | **Reviews & ratings** — customers rate/review products, shopkeepers reply, users vote/report, and admins moderate (hide/restore). |
| 09 | **payment** (`:10009`) | Elixir/Phoenix | **Payments** — Cash-on-Delivery plus online providers (bKash, Nagad, Rocket, SSLCommerz, Stripe); creates payment intents and settles them. |
| 10 | **wallet** (`:10010`, gRPC `:20010`) | Go/Fiber | **Digital wallet & ledger** — customer balances, top-ups, debits/credits, and transaction history. |
| 11 | **reporting** (`:10011`) | Python | **Analytics & reporting** — platform KPIs (GMV, orders, AOV, take-rate), orders-by-period, payment mix, payouts — powers the admin dashboards. |
| 12 | **media** (`:10012`, gRPC `:20012`) | Rust/Actix | **Media & images** — product/shop image upload and storage via object storage (S3-compatible), presigned uploads. |
| 13 | **order** (`:10013`, gRPC `:20013`) | Java/Spring | **Orders & checkout** — the **checkout saga** (orchestrated with Temporal) that reserves stock, charges payment/wallet, and creates the order; plus order history. |
| 14 | **notification** (`:10014`) | Node/Fastify | **Notifications** — multi-channel dispatch (email/SMS/push/WhatsApp), the customer **inbox**, per-channel preferences, and realtime updates. |
| 15 | **api-gateway** (`:10015`) | Go/Echo | **The single edge** — the one door the web app talks to. Routes requests to services, **verifies JWTs** (via the auth key set), applies rate limits, and exposes ops. |
| 16 | **recommendation** (`:10016`, gRPC `:20016`) | Python/FastAPI | **Recommendations** — personalized product feed, "similar products", and trending. |
| 17 | **shipping** (`:10017`, gRPC `:20017`) | Ruby/Rails | **Shipping** — delivery **quotes**, shipment creation, tracking, and carrier/zone routing (graph-based). |
| 18 | **risk-trust** (`:10018`, gRPC `:20018`) | Python/FastAPI | **Risk & trust** — fraud/risk **scoring** at checkout (allow / review / deny), COD risk, and admin-managed risk rules. |

**How a purchase flows through them:** a customer **searches** (05) the
**catalog** (04), adds to **cart** (06), applies a **coupon** (07), and
**checks out** — the **order** service (13) runs a saga that checks **risk** (18),
reserves **catalog** stock (04), takes **payment** (09) or **wallet** (10),
arranges **shipping** (17), and fires **notifications** (14); the customer later
**reviews** (08) the product. Admins watch it all through **reporting** (11).
Everything is fronted by the **gateway** (15) and secured by **auth** (01).

---

## 8. Key platform concepts

- **Passwordless auth:** phone + OTP only. Sessions are encrypted http-only
  cookies managed by the web app's server (the BFF); the browser never holds a raw token.
- **Roles & security:** every route and API is role-gated (`customer`,
  `shopkeeper`, `shop_staff`, `platform_staff`, `admin`); JWTs are RS256-signed by
  Auth and verified at the gateway.
- **Money is integer paisa** (1 Taka = 100 paisa) — no floating-point money.
- **Bilingual:** all content supports Bangla and English.
- **Payments:** COD-first, with wallet and online providers.
- **BFF edge pattern:** browser → web app (`/api/gw/*`, `/api/auth/*`) → gateway → services. Backend ports are never exposed to the browser.

---

## 9. Known limitations (current build)

The web app is deliberately **resilient to backend gaps** — incomplete areas show
honest empty/blocked states rather than errors. Notable items:
- **Storefront is empty until the catalog is seeded** — with no products loaded,
  search/home correctly show "No products". Add catalog data and they populate.
- **Seller shop/storefront + some seller flows** are gated by backend endpoints
  still in progress (shop setup, media list, seller-scoped order list).
- **Shopkeeper self-signup** isn't available yet (accounts sign up as customers;
  seller role assignment is an admin/back-office step).
- **Notifications realtime** falls back to polling where realtime transport isn't wired.
- Full gap-by-gap detail lives in `ui/frontend/GAP_REGISTER.md`.

---

## 10. Quick reference — try it now

```
# Web app
open http://13.250.60.53:3000

# Register / log in (dev): request a code in the UI, then read it back:
curl "http://47.128.217.17:10099/otp/latest?phone=01XXXXXXXXX&purpose=signup"   # or purpose=login

# Health of the platform edge
curl http://13.250.60.53:3000/ready     # web app + gateway + service manifest
curl http://47.128.217.17:10015/ready   # backend gateway
```

Deployment/runbook commands: **`ui/frontend/commands.md`** (web app) and each
service's **`commands.md`** (backend); the full backend platform bring-up is in
**`backend/commands.md`**.
