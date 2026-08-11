# Shop Service — Smoke / Contract Test (`smoke_test/`)

A single bash harness (`test.sh`) that exercises **every** shop endpoint and route on the OpenAPI
surface, authenticates **every** relevant user type (admin, shopkeeper ×2, shop_staff, customer),
asserts the documented success codes plus the reachable failure codes, and drives shop's two
**cross-service** surfaces end-to-end. It writes a machine-readable `result.json` + a human-readable
`smoke.log`, and exits non-zero iff any check **FAILED**.

```text
smoke_test/
├── test.sh            # the harness (curl + bash + stdlib python3)
├── .env.example       # optional config (copy → .env, or export the vars)
├── test_command.md    # this file
├── .gitignore         # ignores .env + out/
└── out/               # result.json + smoke.log land here (git-ignored)
```

Last run against the live deployment (`3.109.183.124`): **PASS=82, FAIL=0, SKIP=0** (≈99 checks; a
single non-gating `WARN` for the admin OTP rate-reset when run from a laptop is expected).

---

## 1. Why this harness needs AUTH + SUPPORT

Shop is **downstream and outbound**, so it can't be tested in isolation:

1. **Writes need a real RS256 token.** Shop verifies the JWT offline against auth's public key, so the
   harness mints **admin / shopkeeper / shop_staff / customer** tokens from **AUTH** (`AUTH_URL`),
   recovering OTP codes from the **SUPPORT** service (`SUPPORT_URL`).
2. **Shop calls auth over gRPC.** Staff-assign calls `auth.LookupShopkeeper` (needs the shared
   `INTERNAL_SERVICE_TOKEN`) — §11 exercises that round-trip.
3. **Shop consumes auth's KYC events.** `dokandar.kyc.approved` → `shopkeeper_kyc_cache` → surfaced as
   `kyc_tier` on `GET /shops/handle/{handle}` — §12 polls that mirror.

All peer endpoints come from the **env** (`SHOP_URL`, `AUTH_URL`, `SUPPORT_URL`).

---

## 2. Prerequisites

| Need | Why |
| --- | --- |
| **`SHOP_URL`** | the service under test (default `http://127.0.0.1:10003`; box `:10003`). |
| **`AUTH_URL`** + **`SUPPORT_URL`** | mint tokens / recover OTP codes. With OTP on, codes are read from SUPPORT (`/otp/latest`). |
| `bash`, `curl`, `python3` (stdlib only) | no extra packages. |
| **JWT key alignment** | shop's `JWT_PUBLIC_KEY_B64` MUST match auth's current signing key; the §4 key-sanity gate detects a mismatch explicitly. |

---

## 3. Configure (optional — every value has a default)

```bash
cp smoke_test/.env.example smoke_test/.env
vim smoke_test/.env            # or just export the vars inline
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `SHOP_URL` | `http://127.0.0.1:10003` | base URL of the shop service (under test) |
| `AUTH_URL` | `http://127.0.0.1:10001` | auth service — used to mint users/tokens + the gRPC target |
| `SUPPORT_URL` | `http://127.0.0.1:10099` | 00-support — preferred OTP-code source (`/otp/latest`) |
| `ADMIN_PHONE` | `01700000000` | seeded platform admin (provisions shopkeepers) |
| `AUTH_CONTAINER` | `dokandar_auth_service_dev` | OTP docker-logs fallback container |
| `AUTH_SSH` / `AUTH_SSH_KEY` | _(unset)_ | OTP recovery + admin rate reset over SSH (laptop) |
| `MIRROR_TIMEOUT` | `40` | seconds to wait for the KYC-tier mirror (auth approve → Kafka → shop) |
| `TIMEOUT` / `HEALTH_TIMEOUT` | `15` / `30` | per-request curl timeouts (s) |
| `NO_COLOR` | _(unset)_ | set to `1` to disable ANSI colour |

---

## 4. Run

```bash
# on the app box (recommended — support/docker reachable locally):
cd /home/ubuntu/03-shop
./smoke_test/test.sh

# from a laptop — point at the box's reachable addresses:
SHOP_URL=http://3.109.183.124:10003 AUTH_URL=http://3.109.183.124:10001 \
SUPPORT_URL=http://3.109.183.124:10099 ./smoke_test/test.sh

# through the API gateway (rewrites /api/v1/shop/*):
SHOP_URL=http://3.109.183.124:10015 AUTH_URL=http://3.109.183.124:10015 \
SUPPORT_URL=http://3.109.183.124:10099 ./smoke_test/test.sh
```

Exit code: **0** if zero FAILs, **1** otherwise (CI-friendly).

---

## 5. What it covers — 15 sections (≈99 checks)

| Section | Endpoint(s) | Sample assertions |
| --- | --- | --- |
| 1. Ops / contract | `/ready` `/health` `/data` `/metrics` `/docs` `/openapi.json` + unknown paths | `/ready` deps postgres,redis; `/health` core gating = postgres,redis,kafka,mongo_logs,apm + **grpc_auth/media/coupon diagnostic non-gating**; `/data` **200\|404 no_snapshot**; HTTPBearer in OpenAPI; bare 404; `POST /ready`→405 |
| 2. Public reads | `/categories`, full `/admin-areas/*` cascade (**divisions→districts→upazilas→unions**, URL-encoded), `/shops/near` (422 without lat/lon, 200 with), unknown id/handle → 404 `shop_not_found` |
| 3. Auth gate | `POST /shops` no token → 401 `token_missing`; bad token → 401 `token_invalid` |
| 4. Mint + **key-sanity gate** | admin (login) + shopkeeper ×2 + shop_staff (created by **SK1's own token**) + customer; shop must accept an auth token (else JWT key drift → loud FAIL) |
| 5. RBAC create | customer → 403 `insufficient_role`; shop_staff → 403; admin → 201 |
| 6. Create + validation | bad handle → 422; missing name → 422; create → 201 (status=draft); duplicate handle → **409** |
| 7. Lifecycle | public GET by id (raw) + by handle (**PII stripped + `kyc_tier`**); PATCH (owner) → 200; activate draft→live → 200; invalid transition → 422/403; **DELETE own shop → 204 (soft delete → status=closed, still readable)** |
| 8. Ownership | SK2 PATCH/activate/delete SK1's shop → **403 `not_owner`** |
| 9. listMine + categories | SK1 own / admin all; shopkeeper private + admin global → 201; duplicate → 409; shop_staff → 403 |
| 10. Hours | replace → 200; public GET → 200; duplicate `day_of_week` → 422 |
| 11. **Staff → auth gRPC** | assign customer → 422 `not_shop_staff_role` (round-trip OK); **5xx/UNAUTHENTICATED → FAIL** (shared-token landmine); SK1 assign own staff → 201; re-assign → 409; remove → 204; SK2 → 403 |
| 12. **KYC tier mirror** | SK1 submit KYC in auth → admin approve → poll `GET /shops/handle/{handle}` until `kyc_tier`=`verified` (kafka-down → WARN; up-but-no-mirror → FAIL) |
| 13. Media presign | `POST /shops/{id}/logo` **and** `/banner` — **recorded, not asserted** (half-built: 200/501/503; currently 501 `not_implemented`) |
| 14. Compat aliases | `GET /me`→200, `POST /me`→201, then `GET /{id}`→200, `PUT /{id}`→200, `POST /{id}/activate`→200 (same handlers; happy path each) |
| 15. Scope | shop has **no gRPC server** (it's a client); 503; non-UUID path → bare 404 by route regex (shop has **no 400**) |

---

## 6. Cross-service + key-mismatch notes

- **JWT key drift** (§4 gate): shop verifies tokens offline; a stale `JWT_PUBLIC_KEY_B64` rejects every
  token (`401 token_invalid`). Fix = sync auth's key into `03-shop/env/.env.<env>` + `docker rm -f`/`run`.
- **§11 shop→auth gRPC** is the real `LookupShopkeeper` test. A customer-as-staff coming back a clean
  role rejection (422) is only possible if the east-west call succeeded; a 5xx/UNAUTHENTICATED is the
  shared `INTERNAL_SERVICE_TOKEN` landmine → hard FAIL with a both-sides diagnostic. The 201 owner-match
  path needs the staff **owned by SK1**, so the harness creates it with **SK1's own token**.
- **§12 KYC mirror** proves auth → Kafka → shop's `shopkeeper_kyc_cache` → public `kyc_tier`.
- **`show()` vs `showByHandle()`**: `GET /shops/{id}` returns the raw model; `GET /shops/handle/{handle}`
  is the public surface that strips PII and adds `kyc_tier` — the mirror test polls the handle endpoint.

> **Infra-down ≠ test failure.** `/health` treats postgres/redis/kafka/mongo_logs/apm as gating, but
> the harness asserts status↔code consistency and WARNs a down dep rather than hard-failing. The three
> `grpc_*` checks are diagnostic-only and never gate.

---

## 7. Output

- **`out/result.json`** — `meta` (shop_url, auth_url, otp_mode, otp_recovery, code_version, tenant, env,
  generated_test_phones), `summary` (PASS/FAIL/SKIP/WARN/INFO/total), `by_category`, full `results`.
- **`out/smoke.log`** — the terminal lines, colour-stripped.
- **stdout** — colourised live log + a final `RESULT: PASS|FAIL` banner.

**Status legend:** `PASS` held · `FAIL` broke (→ exit 1) · `SKIP` not runnable in this mode · `WARN`
non-gating infra observation · `INFO` context.

---

## 8. Side effects & cleanup

Creates orphaned shops / categories / staff and emits `ShopChanged` + (test) KYC events. Each run uses
fresh unique handles (`shop-<epoch>-N`) and phones (`017<epoch>NN`, in `meta.generated_test_phones`), so
reruns don't collide. The baked `my-shop-01` example in Swagger 409s on reruns — expected. DELETE is a
**soft** delete (status→closed), so test shops remain in the table. To clean up, delete by the exact
phone list (auth DB, cascades) and the shop rows by their test handles.
