# Auth Service — Smoke / Contract Test (`smoke_test/`)

A single bash harness (`test.sh`) that exercises **every** auth endpoint over HTTP,
authenticates **every** user type, and asserts the documented success codes plus the
reachable failure codes. It writes a machine-readable `result.json` and a
human-readable `smoke.log`, and exits non-zero iff any check **FAILED**.

```text
smoke_test/
├── test.sh            # the harness (curl + bash + stdlib python3)
├── .env.example       # optional config (copy → .env, or export the vars)
├── test_command.md    # this file
└── out/               # result.json + smoke.log land here (git-ignored)
```

Last run against the live deployment: **PASS=123, FAIL=0, SKIP=0, WARN=0** (137 checks).

---

## 1. Prerequisites

| Need | Why |
| --- | --- |
| **`SUPPORT_URL`** (the 00-support service) | with OTP enabled, the harness reads the verification codes from the support service's API — no docker/SSH needed, and it works from a laptop. Default `http://127.0.0.1:10099` (correct on the box). |
| `bash`, `curl`, `python3` (stdlib only) | no PyJWT/cryptography/argon2 needed; the full RS256-verify check self-SKIPs if PyJWT is absent. |
| Running from a **laptop**? | point `AUTH_URL` + `SUPPORT_URL` at the box's reachable addresses (`:10001` / `:10099`). `AUTH_SSH`/`AUTH_SSH_KEY` are only needed as a fallback and for the admin rate-limit reset. |

---

## 2. OTP modes — the harness adapts automatically

The deployment currently runs `OTP_ENABLED=true`. The harness detects the mode from
`/signup/request` and adapts:

- **OTP on** — `/verify` needs the real 6-digit code. The harness recovers it, in order:
  1. the **support service** `GET {SUPPORT_URL}/otp/latest?phone=…&purpose=…` (preferred — no docker/SSH, works anywhere),
  2. local `docker logs` (on the box),
  3. over SSH (`AUTH_SSH`).
  It also **resets the seeded admin's per-phone OTP rate counter** at startup so repeated
  runs don't trip the `OTP_RATE_PER_HOUR` (=5) limit.
- **OTP off** — `/verify` accepts any code; the full happy path runs purely over HTTP
  and the rate-limit check is reported as NOT-EXERCISED.

If OTP is on but the harness has **no** recovery channel (no `SUPPORT_URL`, not on the
box, no `AUTH_SSH`), it emits one loud `FAIL` in §2 explaining the fix and SKIPs the
OTP-gated flows — it never silently pretends to have tested them.

---

## 3. Configure (optional — every value has a default)

```bash
cp smoke_test/.env.example smoke_test/.env
vim smoke_test/.env            # or just export the vars inline
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `AUTH_URL` | `http://127.0.0.1:10001` | base URL of the auth service |
| `SUPPORT_URL` | `http://127.0.0.1:10099` | the 00-support service — preferred OTP-code source (`/otp/latest`) |
| `ADMIN_PHONE` | `01700000000` | seeded platform admin (must match `DEFAULT_ADMIN_PHONE`) |
| `AUTH_CONTAINER` | `dokandar_auth_service_dev` | container to read OTP codes from (docker-logs fallback) |
| `AUTH_SSH` | _(unset)_ | `user@host` — fallback OTP recovery + admin rate-limit reset (e.g. `ubuntu@13.233.126.113`) |
| `AUTH_SSH_KEY` | _(unset)_ | SSH private key path for `AUTH_SSH` |
| `REDIS_RESET_URL` | _(auto)_ | redis URL to clear the admin OTP rate key; auto-read from `../env/.env.dev` when run inside the repo |
| `TIMEOUT` / `HEALTH_TIMEOUT` | `15` / `30` | per-request curl timeouts (s); `/health` fans out to kafka so it gets longer |
| `REQ_RETRIES` | `2` | retries on a transient `HTTP 000` |
| `OUTPUT_DIR` | `smoke_test/out` | where `result.json` + `smoke.log` go |
| `NO_COLOR` | _(unset)_ | set to `1` to disable ANSI colour |

**Cross-service note:** the auth service has **no synchronous HTTP dependency** on any
peer. It emits domain events via a transactional outbox → Kafka and _serves_ `/jwks` +
gRPC for other services to verify its JWTs. So there are no outbound peer URLs to
configure here; the fleet-standard `NN_*` vars in `.env.example` are accepted-but-unused
(and the loader safely ignores them — they are not valid shell identifiers).

---

## 4. Run

```bash
# on the box (recommended — support/docker reachable locally):
cd /home/ubuntu/01-auth
./smoke_test/test.sh

# from a laptop — OTP codes pulled from the support service (no SSH needed):
AUTH_URL=http://13.233.126.113:10001 SUPPORT_URL=http://13.233.126.113:10099 \
  ./smoke_test/test.sh
#   add AUTH_SSH=ubuntu@13.233.126.113 AUTH_SSH_KEY=~/Desktop/DevOps/mumbai-key.pem
#   so the admin OTP rate-limit can also be reset (needs VPC Redis access).

# through the API gateway (rewrites /api/v1/auth/*):
AUTH_URL=http://127.0.0.1:10015 SUPPORT_URL=http://127.0.0.1:10099 ./smoke_test/test.sh
```

Exit code: **0** if zero FAILs, **1** otherwise (CI-friendly).

---

## 5. What it covers

137 checks across 11 sections (counts from the last green run):

| Section | Endpoint(s) | Sample assertions |
| --- | --- | --- |
| 1. Ops / contract | `/ready` `/health` `/data` `/metrics` `/docs` `/openapi.json` + unknown paths | status↔code consistency; identity block; **all 7** `/health` deps present; `HTTPBearer` in OpenAPI; **bare 404 = zero bytes**; wrong method → 405 |
| 2. OTP mode | `/signup/request` | detects mode; picks recovery channel (support/docker/ssh); resets admin rate limit |
| 3. Signup | `/signup/request` `/signup/verify` | 202/201 happy path; 403 non-customer; 409 dup phone; **409 dup email** (deep); 422 bad phone/short name; **JWT claims** |
| 4. /me | `/me` | 200 with token; 401 `token_missing`; 401 `token_invalid`; **401 tampered-signature** (deep) |
| 5. Refresh | `/refresh` | 200 rotation; reuse → 401 `refresh_reuse_detected`; **sibling token revoked after reuse → 401**; 422; 401 unknown |
| 6. Logout | `/logout` | 204; idempotent 204; 422 empty; **refresh-after-logout → 401** (deep) |
| 7. Login | `/login/request` `/login/verify` | 202 anti-enum; 422 bad phone; 401 unknown phone |
| 8. RBAC + roles | `/users` `/me` | admin bootstrap; **every role authenticates**; full role matrix (admin→shopkeeper 201, customer→any 403, shopkeeper→shop_staff 201, shopkeeper→admin 403, shop_staff→customer 201, shop_staff→shop_staff 403, platform_staff→any 403); 409 dup; 422 bad phone |
| 9. KYC | `/kyc/submit` `/kyc/me` `/kyc/queue` `/kyc/{id}/approve` `/kyc/{id}/reject` | shopkeeper-only 403; **nid + trade_license wrong-prefix 422**; 202 submit; 409 re-submit; queue RBAC (admin + platform_staff); bad-uuid 422; 404; approve+reject lifecycle; 409 re-decide; 422 short reason |
| 10. JWT | `/jwks` | RSA/RS256/kid/n; RS256 verify of a real access token |
| 11. Rate limit / scope | `/signup/request` | OTP `429` throttle (OTP-on); transparency markers for what is not exercised |

The **(deep)** assertions above also guard the recent fixes — duplicate-email→409 and
tampered-token/refresh-revocation — so a regression on any of them turns the suite red.

### Not exercised (stated, not faked — see the `scope` rows in `result.json`)

- **503 `dependency_unavailable`** — needs a live dependency taken down; out of scope for a smoke test.
- **413 `payload_too_large`** (`/kyc/submit`) — needs a proxy/body-size limit.
- **gRPC** (`auth.proto`, port `20001`) — this is an HTTP/curl harness; gRPC needs `grpcurl` + the proto.

> **Infra-down ≠ test failure.** `/health` returning **503 because kafka is down is
> correct** (kafka is non-gating by design — events buffer in the outbox). The harness
> asserts status↔code consistency and that all 7 checks are *present*, then reports any
> down dep as **WARN**, never FAIL.

---

## 6. Output

- **`out/result.json`** — structured: `meta` (auth_url, otp_mode, otp_recovery, code_version, tenant, env, generated_test_phones), `summary` (PASS/FAIL/SKIP/WARN/INFO/total), `by_category`, and the full `results` array.
- **`out/smoke.log`** — the terminal lines, colour-stripped.
- **stdout** — colourised live log + a final `RESULT: PASS|FAIL` banner.

**Status legend:** `PASS` held · `FAIL` broke (→ exit 1) · `SKIP` not runnable in this mode · `WARN` non-gating infra observation · `INFO` context.

---

## 7. Side effects & cleanup

There is **no DELETE endpoint**, so successful runs leave orphaned test users in the
`users` table. Each run uses fresh unique phones (`017<epoch>NN`, listed in
`meta.generated_test_phones`), so reruns don't collide.

- The harness **never** mutates the seeded admin destructively (it only logs in as admin
  and reads `/me`). Reuse/rotation tests run **only on test-created users**.
- **Event fan-out:** every signup / `/users` / KYC decision writes a row to the **outbox**
  (`UserCreated`, `KycSubmitted`, `KycApproved`, `KycRejected`). Kafka is currently down,
  so these buffer and **flush to the fleet when kafka recovers** — downstream consumers
  (profile, notification, wallet) will then process the test events. Be aware of this
  post-recovery flush; it's inherent to testing approve/reject against a live shared env.
- **Cleanup (optional).** Delete by the **exact** phone list from
  `meta.generated_test_phones` — never a `LIKE` prefix (it would match real users).
  `users.created_by` is a self-FK with no cascade, so delete the whole run's list at once:

  ```sql
  -- run against the auth postgres DB; paste this run's exact phones:
  DELETE FROM users
   WHERE phone IN ('01738566001','01738566002' /* …all from meta.generated_test_phones… */)
     AND role <> 'admin';            -- belt-and-braces: never delete the platform admin
  -- refresh_tokens + kyc_submissions cascade via ON DELETE CASCADE.
  ```

---

## 8. Note on the refresh-reuse fix

An earlier run of this harness surfaced a real security bug: a replayed (rotated) refresh
token returned `401 refresh_reuse_detected`, but the **sibling token kept working** — the
spec's "replay → entire family revoked" lockdown was being **rolled back**. Root cause: the
family-revoke `UPDATE` ran inside `session_scope()` and was undone when the handler raised.
**Fixed** in `app/domain/tokens.py` by persisting the family revocation in its own committed
session before raising. The §5 assertion (`sibling token after family revoke → 401`) now
passes and guards against regression.
