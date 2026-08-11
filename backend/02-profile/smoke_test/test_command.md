# Profile Service — Smoke / Contract Test (`smoke_test/`)

A single bash harness (`test.sh`) that exercises **every** profile endpoint over HTTP
and asserts the documented success codes plus the reachable failure codes. It writes a
machine-readable `result.json` and a human-readable `smoke.log`, and exits non-zero iff
any check **FAILED**.

```text
smoke_test/
├── test.sh            # the harness (curl + bash + stdlib python3)
├── .env.example       # optional config (copy → .env, or export the vars)
├── test_command.md    # this file
├── .gitignore         # ignores .env + out/
└── out/               # result.json + smoke.log land here (git-ignored)
```

Last run against the live deployment (`<deploy-host>`): **PASS=124, FAIL=0, SKIP=0** (≈140 checks; the
exact total + a possible non-gating `WARN` depend on auth's OTP mode and on running from a laptop without
Redis access — that produces a single WARN on the admin OTP rate-limit reset, which is expected and non-gating).

---

## 1. Why this harness needs AUTH + SUPPORT

Profile is a **downstream** service, so — unlike the auth harness — it can't test itself in
isolation:

1. **Protected routes need a real RS256 token.** Profile verifies the JWT *offline* against
   auth's public key (`JWT_PUBLIC_KEY_B64`); it never mints tokens. So the harness mints
   real users/tokens from **AUTH** (`AUTH_URL`) and recovers OTP codes from the **SUPPORT**
   service (`SUPPORT_URL`) — exactly the auth harness's flow.
2. **A profile row only exists after a Kafka event.** Profile creates a user's profile when it
   consumes auth's `dokandar.user.created`. The harness mints a customer at auth, then **polls
   `/me` until the profile materializes** (§5) — this is the core auth → Kafka → profile
   integration assertion.

All peer endpoints come from the **env** (`PROFILE_URL`, `AUTH_URL`, `SUPPORT_URL`), per the
platform convention. Profile makes **no synchronous HTTP call** to any peer (Media is gRPC and
diagnostic-only on `/health`), so there are no other peer URLs to configure.

---

## 2. Prerequisites

| Need | Why |
| --- | --- |
| **`PROFILE_URL`** | the service under test (default `http://127.0.0.1:10002`; box `:10002`). |
| **`AUTH_URL`** + **`SUPPORT_URL`** | mint tokens / recover OTP codes. With OTP **off** on auth, SUPPORT isn't strictly needed; with OTP **on**, codes are read from SUPPORT (`/otp/latest`). |
| `bash`, `curl`, `python3` (stdlib only) | no extra Python packages required. |
| **JWT key alignment** | profile's `JWT_PUBLIC_KEY_B64` MUST match auth's current signing key. The harness detects a mismatch explicitly (see §5 note). |

---

## 3. Configure (optional — every value has a default)

```bash
cp smoke_test/.env.example smoke_test/.env
vim smoke_test/.env            # or export the vars inline
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `PROFILE_URL` | `http://127.0.0.1:10002` | base URL of the profile service (under test) |
| `AUTH_URL` | `http://127.0.0.1:10001` | auth service — used to mint users/tokens |
| `SUPPORT_URL` | `http://127.0.0.1:10099` | 00-support — OTP-code source (`/otp/latest`) |
| `ADMIN_PHONE` | `01700000000` | seeded platform admin (for `/admin/profiles`) |
| `AUTH_CONTAINER` | `dokandar_auth_service_dev` | OTP docker-logs fallback container |
| `AUTH_SSH` / `AUTH_SSH_KEY` | _(unset)_ | OTP recovery + admin rate reset over SSH (laptop) |
| `MATERIALIZE_TIMEOUT` | `40` | seconds to wait for the `UserCreated` event → profile row |
| `TIMEOUT` / `HEALTH_TIMEOUT` | `15` / `30` | per-request curl timeouts (s) |
| `NO_COLOR` | _(unset)_ | set to `1` to disable ANSI colour |

---

## 4. Run

```bash
# on the app box (recommended — support/docker reachable locally):
cd /home/ubuntu/02-profile
./smoke_test/test.sh

# from a laptop — point at the box's reachable addresses:
PROFILE_URL=http://<deploy-host>:10002 AUTH_URL=http://<deploy-host>:10001 \
SUPPORT_URL=http://<deploy-host>:10099 ./smoke_test/test.sh

# through the API gateway (rewrites /api/v1/profile/*):
PROFILE_URL=http://<deploy-host>:10015 AUTH_URL=http://<deploy-host>:10015 \
SUPPORT_URL=http://<deploy-host>:10099 ./smoke_test/test.sh
```

Exit code: **0** if zero FAILs, **1** otherwise (CI-friendly).

---

## 5. What it covers

≈140 checks across 14 sections (counts from the last green run):

| Section | Endpoint(s) | Sample assertions |
| --- | --- | --- |
| 1. Ops / contract | `/ready` `/health` `/data` `/metrics` `/docs` `/openapi.json` + unknown paths | status↔code; identity.code_version; `/ready` deps = **postgres, redis**; `/health` checks = **postgres, redis, kafka, mongo_logs, apm** (gating) + **grpc_media** (diagnostic, `not_configured`); `/data` = **`data/<tenant>/collect.sh` snapshot** (200 `kind`+`host`, like auth; or 404 `no_snapshot`); **bare zero-byte 404** at top level AND mounted subpath; `POST /ready` → 405 + envelope |
| 2. Public geo | `/geo/divisions` → `/districts` → `/upazilas` → `/unions` | 200 + non-empty; **walks the chain to discover valid codes** (no hardcoding); unknown code → **404 with `not_found` envelope** |
| 3. Auth gate | `/me` | no token → 401 `token_missing`; malformed → 401 `token_invalid` |
| 4. Mint **all user types** | auth `signup`/`login`/`users` | OTP-mode detect; **key-sanity gate** (see §6); mint **customer** (C1 self-signup), **C2** (isolation), **admin** (login), and admin-provision + OTP-login **shopkeeper** ×2, **shop_staff**, **platform_staff** |
| 5. Materialization | `/me` (poll) | C1 (customer) profile appears via `UserCreated` Kafka event → 200 (the core integration assertion) |
| 6. `/me` body | `/me` | `user_id`/`phone` match; `kyc`=unverified; `locale`=bn default; tampered-signature → 401 |
| 7. PATCH/PUT `/me` | `/me` | update reflected + persists; PUT alias; negatives → 422 `invalid_request` (locale/gender/dob), `phone_invalid` (whatsapp), `validation_error` (bad JSON) |
| 8. Avatar | `/me/avatar` | missing `media_id` → 422; valid UUID → 200 + `avatar_url=media://…` |
| 9. Addresses | `/me/addresses[...]` | create/list/get/patch/set-default/delete; `phone_invalid`; **`geo_chain_invalid`** (division A × district B); `invalid_uuid` (400) vs unknown (404 `not_found`); **`default_in_use`** (409) invariant; `/me.default_address` reflects |
| 10. Isolation | `/me/addresses/{id}` | C1 **cannot** read C2's address → 404 (ownership scoped by token `sub`) |
| 11. **All-role materialization** | `/me` (poll) | profile shell appears for **shopkeeper, shop_staff, platform_staff** (and a 2nd shopkeeper) — proves the consumer handles every role's `UserCreated`, not just customers |
| 12. **RBAC matrix** | `/admin/profiles/{user_id}` | **admin → 200**, **platform_staff → 200**; **shopkeeper / shop_staff / customer → 403 `forbidden`**; admin unknown → 404, bad-uuid → 400 |
| 13. **KYC mirroring** (cross-service) | auth `kyc/submit` `kyc/{id}/approve\|reject` → `/me` (poll) | shopkeeper KYC decisions in **auth** flow to **`profile.kyc`** via Kafka: SK1 submit→`submitted`→approve→`verified`; SK2 reject→`rejected` |
| 14. Scope | — | gRPC, 503, `user.updated`, and the avatar-UUID observation, stated not faked |

### Not exercised / observations (stated, not faked — see the `scope` rows in `result.json`)

- **gRPC `ProfileQuery`** (`profile.proto`, `:20002`) — this is an HTTP/curl harness; gRPC needs `grpcurl` + the proto.
- **503 `dependency_unavailable`** — needs a live dependency taken down; out of scope for a smoke test.
- **`POST /me/avatar` with a non-UUID `media_id`** — `setAvatar` does **not** format-check `media_id`, and the column is `UUID`, so a non-UUID value reaches pgx and **500s** (SQLSTATE `22P02` leak). This is a latent bug; the harness passes a generated UUID for the documented 200 path and does **not** assert the 500 (smoke tests assert documented behavior). Worth a one-line `uuid.Parse` guard in `handlers.go:setAvatar`, mirroring the address-path `reqValidUUID`.

> **Infra-down ≠ test failure.** `/health` here treats kafka/postgres/redis/mongo_logs/apm as **gating** (a real 503 if one is down), but the harness asserts status↔code consistency and WARNs a down dep rather than hard-failing. `grpc_media` is diagnostic-only and never gates.

---

## 6. The JWT key-mismatch gate (important)

Profile verifies tokens **offline** with its configured `JWT_PUBLIC_KEY_B64`. If that key is
stale (doesn't match auth's current signing key — the fleet's known shared-secret landmine),
**every** token is rejected with `401 token_invalid (crypto/rsa: verification error)` and no
authenticated route is testable.

§4 detects this with a **key-sanity gate**: right after minting C1, it does one `GET /me`. A
`401 token_invalid` on a *freshly-minted* token is reported as a single, clear root-cause FAIL
(`profile accepts auth-issued token`), and §5–§13 are skipped — instead of surfacing as a
confusing "materialization" or "admin" failure.

**Fix when it trips:** copy auth's `JWT_PUBLIC_KEY_B64` into `02-profile/env/.env.<env>` and
restart profile with `docker rm -f` + `docker run` (the `--env-file` value is a run-time
snapshot — `docker restart` will **not** pick up the edit).

---

## 7. Output

- **`out/result.json`** — `meta` (profile_url, auth_url, otp_mode, otp_recovery, code_version,
  tenant, env, generated_test_phones), `summary` (PASS/FAIL/SKIP/WARN/INFO/total), `by_category`,
  and the full `results` array.
- **`out/smoke.log`** — the terminal lines, colour-stripped.
- **stdout** — colourised live log + a final `RESULT: PASS|FAIL` banner.

**Status legend:** `PASS` held · `FAIL` broke (→ exit 1) · `SKIP` not runnable in this mode ·
`WARN` non-gating infra observation · `INFO` context.

---

## 8. Side effects & cleanup

There is **no DELETE user endpoint** in auth, so each run leaves orphaned test users (and their
profiles, materialized via Kafka) in the `auth` and `profile` DBs. Each run uses fresh unique
phones (`017<epoch>NN`, listed in `meta.generated_test_phones`), so reruns don't collide.

- Addresses created during the run are soft-deleted where the flow allows; some (A2, C2's) remain.
- Every signup / address write emits Kafka events (`UserCreated`, `ProfileChanged`,
  `AddressChanged`); downstream consumers (search trending, notification) will process the test
  events. This is inherent to testing against a live shared environment.
- To clean up, delete by the **exact** phone list in `meta.generated_test_phones` from the auth DB
  (cascades) and the matching `user_id`s from the profile DB — never a `LIKE` prefix.
