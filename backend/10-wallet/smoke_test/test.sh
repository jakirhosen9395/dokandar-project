#!/usr/bin/env bash
# =============================================================================
# DOKANDAR Wallet Service (10-wallet) — smoke / contract test harness
# -----------------------------------------------------------------------------
# Exercises EVERY wallet endpoint and asserts the documented success + failure
# codes / error codes / metric names. Wallet is east-west AND customer-facing:
#   * /me* needs a real RS256 customer token, minted from AUTH (AUTH_URL) with
#     OTPs recovered from SUPPORT (SUPPORT_URL),
#   * /debit /credit /balance need the shared INTERNAL_SERVICE_TOKEN sent as
#     header x-internal-token (read from ../env/.env.dev unless overridden).
#
# Design mirrors 01-auth/02-profile: `set -uo pipefail` (a failed assertion is
# data, not an abort), stdlib python3 only, result.json from an EXIT trap,
# infra-down reported INFO/WARN (never FAIL). Exit 0 iff FAIL==0.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

load_env_file() {
  local f="$1" line key val
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|\#*) continue ;; esac
    [[ "$line" == [A-Za-z_]*=* ]] || continue
    key="${line%%=*}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [ -n "${!key:-}" ] && continue
    val="${line#*=}"
    if [[ "$val" =~ ^(.*[^[:space:]])[[:space:]]+#.* ]]; then val="${BASH_REMATCH[1]}"; fi
    val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    export "$key=$val"
  done < "$f"
}
load_env_file "$SCRIPT_DIR/.env"
# read INTERNAL_SERVICE_TOKEN (+ others) from the rendered service env if unset
load_env_file "$SCRIPT_DIR/../env/.env.dev"

# --- configuration (env-overridable) ----------------------------------------
WALLET_URL="${WALLET_URL:-http://127.0.0.1:10010}"
AUTH_URL="${AUTH_URL:-http://127.0.0.1:10001}"
SUPPORT_URL="${SUPPORT_URL:-http://127.0.0.1:10099}"
ADMIN_PHONE="${ADMIN_PHONE:-01700000000}"
AUTH_CONTAINER="${AUTH_CONTAINER:-dokandar_auth_service_dev}"
INTERNAL_SERVICE_TOKEN="${INTERNAL_SERVICE_TOKEN:-}"
WALLET_GRPC="${WALLET_GRPC:-127.0.0.1:20010}"
TIMEOUT="${TIMEOUT:-15}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-30}"
REQ_RETRIES="${REQ_RETRIES:-2}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/out}"
RESULT_JSON="${RESULT_JSON:-$OUTPUT_DIR/result.json}"
LOG="${LOG_FILE:-$OUTPUT_DIR/smoke.log}"
AUTH_SSH="${AUTH_SSH:-}"; AUTH_SSH_KEY="${AUTH_SSH_KEY:-}"
AUTH_SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
[ -n "$AUTH_SSH_KEY" ] && AUTH_SSH_OPTS="-i $AUTH_SSH_KEY $AUTH_SSH_OPTS"

mkdir -p "$OUTPUT_DIR"
TMPD="$(mktemp -d)"; BODYF="$TMPD/body"; RESULTS_TSV="$TMPD/results.tsv"
SEQ_FILE="$TMPD/seq"; PHONES_FILE="$TMPD/phones"
: > "$RESULTS_TSV"; : > "$LOG"; printf '0' > "$SEQ_FILE"; : > "$PHONES_FILE"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''; fi

SMOKE_STARTED="$(date -u +%FT%TZ)"
MODE="unknown"; OTP_RECOVERY="none"; OTP_BLOCKED=0
CODE_VERSION="?"; TENANT="?"; ENVNAME="?"

# =============================================================================
# recording + assertions
# =============================================================================
record() {
  local st="$1" cat="$2" name="$3" http="${4:-}" exp="${5:-}" det="${6:-}"
  det=${det//$'\t'/ }; det=${det//$'\n'/ }
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$st" "$cat" "$name" "$http" "$exp" "$det" >> "$RESULTS_TSV"
  local sym col extra=""
  case "$st" in
    PASS) sym="[PASS]"; col=$GREEN;; FAIL) sym="[FAIL]"; col=$RED;;
    SKIP) sym="[SKIP]"; col=$YELLOW;; WARN) sym="[WARN]"; col=$YELLOW;;
    INFO) sym="[INFO]"; col=$BLUE;;  *) sym="[????]"; col=$NC;;
  esac
  [ -n "$http" ] && extra=" (HTTP $http${exp:+, want $exp})"
  [ -n "$det" ] && extra="$extra — $det"
  printf '%s %s :: %s%s\n' "$sym" "$cat" "$name" "$extra" >> "$LOG"
  printf '%b%s %s :: %s%s%b\n' "$col" "$sym" "$cat" "$name" "$extra" "$NC"
}
assert_code() { if [ "$4" = "$3" ]; then record PASS "$1" "$2" "$4" "$3" "${5:-}"; else record FAIL "$1" "$2" "$4" "$3" "${5:-}"; fi; }
assert_eq()   { local lbl="${5:-value}"; if [ "$3" = "$4" ]; then record PASS "$1" "$2" "" "" "$lbl='$3'"; else record FAIL "$1" "$2" "" "" "$lbl='$3' want '$4'"; fi; }
assert_nonempty() { if [ -n "$3" ]; then record PASS "$1" "$2" "" "" "${4:-field} present"; else record FAIL "$1" "$2" "" "" "${4:-field} missing/empty"; fi; }

# =============================================================================
# HTTP + JSON helpers
# =============================================================================
# _http BASE METHOD PATH [BODY] [TOKEN] [INTERNAL] [TIMEOUT]
_http() {
  local base="$1" m="$2" p="$3" body="${4:-}" tok="${5:-}" intok="${6:-}" to="${7:-$TIMEOUT}"
  local a=(-s -S -m "$to" -o "$BODYF" -w '%{http_code} %{size_download} %{content_type}' -X "$m" "$base$p")
  [ -n "$body" ] && a+=(-H 'Content-Type: application/json' --data "$body")
  [ -n "$tok" ]  && a+=(-H "Authorization: Bearer $tok")
  [ -n "$intok" ] && a+=(-H "x-internal-token: $intok")
  local attempt=0 out rest
  while :; do
    out=$(curl "${a[@]}" 2>/dev/null) || out="${out:-000 0 }"
    RESP_CODE=${out%% *}; rest=${out#* }; RESP_SIZE=${rest%% *}; RESP_CT=${rest#* }
    [ -z "$RESP_CODE" ] && RESP_CODE="000"
    RESP_BODY=$(cat "$BODYF" 2>/dev/null || true)
    { [ "$RESP_CODE" != "000" ] || [ "$attempt" -ge "$REQ_RETRIES" ]; } && break
    attempt=$((attempt + 1)); sleep 0.6
  done
}
req()  { _http "$WALLET_URL" "$@"; }   # service under test
areq() { _http "$AUTH_URL" "$@"; }     # auth (token minting)
# ireq METHOD PATH [BODY] — internal call with x-internal-token
ireq() { _http "$WALLET_URL" "$1" "$2" "${3:-}" "" "$INTERNAL_SERVICE_TOKEN"; }

jget() {
  python3 -c '
import sys, json
try: d = json.loads(sys.stdin.read())
except Exception: print(""); sys.exit(0)
for p in sys.argv[1].split("."):
    if isinstance(d, dict): d = d.get(p)
    elif isinstance(d, list):
        try: d = d[int(p)]
        except Exception: d = None
    else: d = None
    if d is None: break
print("" if d is None else d)' "$1"
}
jf() { printf '%s' "$RESP_BODY" | jget "$1"; }
gen_uuid() { python3 -c 'import uuid;print(uuid.uuid4())'; }

RUN_SALT=$(( $(date +%s) % 1000000 ))
gen_phone() {
  local n; n=$(( $(cat "$SEQ_FILE" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$SEQ_FILE"
  local ph; ph=$(printf '017%06d%02d' "$RUN_SALT" "$((n % 100))"); printf '%s\n' "$ph" >> "$PHONES_FILE"; printf '%s' "$ph"
}

# --- OTP recovery: support → docker logs → SSH ------------------------------
read_otp_support() {
  [ -n "$SUPPORT_URL" ] || return 0
  curl -s -m 8 "$SUPPORT_URL/otp/latest?phone=$1&purpose=$2" 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
print(d.get("code", "") if isinstance(d, dict) else "")' 2>/dev/null
}
read_otp_logs() {
  local phone="$1" purpose="$2" code logs=""
  code=$(read_otp_support "$phone" "$purpose"); [ -n "$code" ] && { printf '%s' "$code"; return; }
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$AUTH_CONTAINER"; then
    logs=$(docker logs --tail 600 "$AUTH_CONTAINER" 2>&1)
  elif [ -n "$AUTH_SSH" ]; then
    logs=$(ssh $AUTH_SSH_OPTS "$AUTH_SSH" "docker logs --tail 600 $AUTH_CONTAINER 2>&1" 2>/dev/null)
  else return 0; fi
  printf '%s\n' "$logs" | grep "DEV-OTP" | grep "phone=$phone" | grep "purpose=$purpose" \
    | tail -1 | grep -oE 'code=[0-9]+' | grep -oE '[0-9]+' | tail -1
}
support_reachable() { [ -n "$SUPPORT_URL" ] && [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$SUPPORT_URL/health" 2>/dev/null)" = "200" ]; }
otp_code_for() {
  [ "$MODE" = "on" ] || { printf ''; return; }
  local i code="" avoid="${3:-}"
  for i in $(seq 1 12); do
    code=$(read_otp_logs "$1" "$2"); [ -n "$code" ] && [ "$code" != "$avoid" ] && { printf '%s' "$code"; return; }; sleep 0.5
  done
  printf '%s' "$code"
}

# --- token minting -----------------------------------------------------------
mint_customer() {
  local phone="$1" name="$2"
  local prev; prev=$(read_otp_logs "$phone" signup)
  areq POST /api/v1/auth/signup/request "{\"phone\":\"$phone\"}"
  local code body; code=$(otp_code_for "$phone" signup "$prev")
  body="{\"phone\":\"$phone\",\"name\":\"$name\",\"role\":\"customer\""
  [ -n "$code" ] && body="$body,\"code\":\"$code\""; body="$body}"
  areq POST /api/v1/auth/signup/verify "$body"
  MC_CODE="$RESP_CODE"; MC_ACCESS=""; MC_ID=""
  if [ "$RESP_CODE" = "201" ]; then MC_ACCESS=$(jf access_token); MC_ID=$(jf user.id); fi
}

section() { printf '\n%b===== %s =====%b\n' "$BOLD" "$1" "$NC"; printf '\n===== %s =====\n' "$1" >> "$LOG"; }

# =============================================================================
# EXIT trap
# =============================================================================
finish() {
  local finished phones; finished="$(date -u +%FT%TZ)"; phones=$(paste -sd, "$PHONES_FILE" 2>/dev/null || true)
  SMOKE_FINISHED="$finished" SMOKE_STARTED="$SMOKE_STARTED" \
  M_WALLET_URL="$WALLET_URL" M_AUTH_URL="$AUTH_URL" M_MODE="$MODE" M_REC="$OTP_RECOVERY" \
  M_CV="$CODE_VERSION" M_TENANT="$TENANT" M_ENV="$ENVNAME" M_PHONES="$phones" \
  python3 - "$RESULTS_TSV" "$RESULT_JSON" <<'PYEOF'
import sys, json, os
from collections import Counter, OrderedDict
tsv, out = sys.argv[1], sys.argv[2]
rows = []
try:
    with open(tsv) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line: continue
            parts = line.split("\t")
            while len(parts) < 6: parts.append("")
            st, cat, name, http, exp, det = parts[:6]
            rows.append({"status": st, "category": cat, "name": name, "http_code": http, "expected": exp, "detail": det})
except FileNotFoundError:
    pass
c = Counter(r["status"] for r in rows)
summary = OrderedDict((k, c.get(k, 0)) for k in ("PASS", "FAIL", "SKIP", "WARN", "INFO"))
summary["total"] = len(rows)
cats = OrderedDict()
for r in rows: cats.setdefault(r["category"], Counter())[r["status"]] += 1
doc = OrderedDict()
doc["meta"] = OrderedDict([
    ("service", "10-wallet"), ("wallet_url", os.environ.get("M_WALLET_URL", "")),
    ("auth_url", os.environ.get("M_AUTH_URL", "")), ("otp_mode", os.environ.get("M_MODE", "")),
    ("otp_recovery", os.environ.get("M_REC", "")), ("code_version", os.environ.get("M_CV", "")),
    ("tenant", os.environ.get("M_TENANT", "")), ("env", os.environ.get("M_ENV", "")),
    ("started_at", os.environ.get("SMOKE_STARTED", "")), ("finished_at", os.environ.get("SMOKE_FINISHED", "")),
    ("generated_test_phones", sorted({p for p in os.environ.get("M_PHONES", "").split(",") if p})),
])
doc["summary"] = summary
doc["by_category"] = {k: dict(v) for k, v in cats.items()}
doc["results"] = rows
with open(out, "w") as f: json.dump(doc, f, indent=2); f.write("\n")
verdict = "FAIL" if summary["FAIL"] else "PASS"
print(); print("=" * 64)
print(f"  RESULT: {verdict}   PASS={summary['PASS']} FAIL={summary['FAIL']} "
      f"SKIP={summary['SKIP']} WARN={summary['WARN']} INFO={summary['INFO']} (total {summary['total']})")
print(f"  report: {out}"); print("=" * 64)
PYEOF
  rm -rf "$TMPD" 2>/dev/null || true
  local fails; fails=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["summary"]["FAIL"])' "$RESULT_JSON" 2>/dev/null || echo 1)
  [ "$fails" = "0" ] && exit 0 || exit 1
}
trap finish EXIT

printf '%bDOKANDAR wallet smoke test%b  →  %s\n' "$BOLD" "$NC" "$WALLET_URL"
printf 'auth=%s  support=%s\nstarted %s\n' "$AUTH_URL" "$SUPPORT_URL" "$SMOKE_STARTED"

# --- preflight ---------------------------------------------------------------
if ! req GET /ready || [ "$RESP_CODE" = "000" ]; then
  record FAIL "preflight" "GET /ready reachable" "$RESP_CODE" "200" "cannot reach $WALLET_URL — on the box use http://127.0.0.1:10010"; exit 1
fi
CODE_VERSION=$(jf identity.code_version); TENANT=$(jf identity.tenant); ENVNAME=$(jf identity.env)
record INFO "preflight" "service identity" "" "" "code_version=$CODE_VERSION tenant=$TENANT env=$ENVNAME"
if ! areq GET /ready || [ "$RESP_CODE" = "000" ]; then
  record WARN "preflight" "AUTH /ready reachable" "$RESP_CODE" "200" "cannot reach $AUTH_URL — token minting (all customer sections) skipped"; AUTH_DOWN=1
else AUTH_DOWN=0; fi
[ -n "$INTERNAL_SERVICE_TOKEN" ] && record INFO "preflight" "internal token" "" "" "loaded (len=${#INTERNAL_SERVICE_TOKEN})" \
  || record WARN "preflight" "internal token" "" "" "INTERNAL_SERVICE_TOKEN empty — internal guard runs in dev-bypass mode"

# =============================================================================
section "1. Operational / contract surface"
# =============================================================================
req GET /ready
RDY_STATUS=$(jf status)
if [ "$RESP_CODE" = "200" ]; then assert_eq "ops" "/ready status==ready when 200" "$RDY_STATUS" "ready" "status"
elif [ "$RESP_CODE" = "503" ]; then assert_eq "ops" "/ready status==not_ready when 503" "$RDY_STATUS" "not_ready" "status"
else record FAIL "ops" "/ready code is 200|503" "$RESP_CODE" "200|503"; fi
assert_nonempty "ops" "/ready identity.code_version" "$(jf identity.code_version)" "code_version"
assert_eq "ops" "/ready gates on postgres ONLY (dep[0])" "$(jf dependencies.0.name)" "postgres" "dep[0]"
assert_eq "ops" "/ready has no second dependency (postgres-only gate)" "$(jf dependencies.1.name)" "" "dep[1]"

req GET /health "" "" "" "$HEALTH_TIMEOUT"
HLT_STATUS=$(jf status)
if [ "$RESP_CODE" = "200" ]; then assert_eq "ops" "/health status==healthy when 200" "$HLT_STATUS" "healthy" "status"
elif [ "$RESP_CODE" = "503" ]; then assert_eq "ops" "/health status==unhealthy when 503" "$HLT_STATUS" "unhealthy" "status"
else record FAIL "ops" "/health code is 200|503" "$RESP_CODE" "200|503"; fi
for dep in postgres redis kafka mongo_logs elasticsearch; do
  ok=$(jf "checks.$dep.ok")
  if [ -z "$ok" ]; then record FAIL "ops" "/health has check: $dep" "" "" "missing from checks{}"
  elif [ "$ok" = "True" ]; then record INFO "ops" "/health dep $dep" "" "" "ok: $(jf checks.$dep.detail)"
  else record WARN "ops" "/health dep $dep DOWN (non-gating except postgres)" "" "" "$(jf checks.$dep.detail)"; fi
done
assert_nonempty "ops" "/health observability.apm_service_name" "$(jf observability.apm_service_name)" "apm_service_name"

req GET /data
if [ "$RESP_CODE" = "200" ]; then record PASS "ops" "/data → 200 (snapshot + identity)" "200" "200" "kind=$(jf kind)"
elif [ "$RESP_CODE" = "404" ]; then assert_eq "ops" "/data 404 → no_snapshot" "$(jf error.code)" "no_snapshot" "code"
else record FAIL "ops" "/data 200|404" "$RESP_CODE" "200|404"; fi

req GET /metrics
{ [ "$RESP_CODE" != "200" ] || [ "${RESP_SIZE:-0}" = "0" ]; } && { sleep 0.5; req GET /metrics; }
assert_code "ops" "GET /metrics" "200" "$RESP_CODE"
for metric in http_requests_total wallet_credits_total wallet_debits_total wallet_cashback_granted_total \
              wallet_insufficient_balance_total wallet_outbox_pending wallet_outbox_published_total; do
  if grep -q "$metric" <<<"$RESP_BODY"; then record PASS "ops" "/metrics exposes $metric" "" "" "present"
  else record FAIL "ops" "/metrics exposes $metric" "" "" "missing"; fi
done
grep -q 'service="10-wallet"' <<<"$RESP_BODY" && record PASS "ops" "/metrics service label == 10-wallet" "" "" "present" \
  || record WARN "ops" "/metrics service label" "" "" "service=\"10-wallet\" not yet observed (no traffic on that series?)"

req GET /docs
assert_code "ops" "GET /docs" "200" "$RESP_CODE"
case "$RESP_CT" in *text/html*) record PASS "ops" "/docs is text/html" "" "" "$RESP_CT";; *) record WARN "ops" "/docs content-type" "" "" "got '$RESP_CT'";; esac
req GET /openapi.json
assert_code "ops" "GET /openapi.json" "200" "$RESP_CODE"
assert_nonempty "ops" "/openapi.json has openapi version" "$(jf openapi)" "openapi"
assert_eq "ops" "/openapi.json wires bearerJwt scheme" "$(jf components.securitySchemes.bearerJwt.scheme)" "bearer" "scheme"

# bare 404 — zero bytes, no body
req GET /this-path-does-not-exist
assert_code "ops" "unknown path → 404" "404" "$RESP_CODE"
assert_eq "ops" "  bare 404 body is zero-byte" "$RESP_SIZE" "0" "bytes"

# =============================================================================
section "2. Auth gate (key sanity)"
# =============================================================================
req GET /api/v1/wallet/me
assert_code "authz" "/me no token → 401" "401" "$RESP_CODE"
assert_eq "authz" "  code=missing_token" "$(jf error.code)" "missing_token" "code"
req GET /api/v1/wallet/me "" "garbage.token.value"
assert_code "authz" "/me malformed token → 401" "401" "$RESP_CODE"

# =============================================================================
section "3. Mint a customer + KEY-SANITY gate"
# =============================================================================
C1_ACCESS=""; C1_ID=""; TOKENS_OK=0
if [ "${AUTH_DOWN:-0}" = "1" ]; then
  record SKIP "mint" "customer minting" "" "" "AUTH unreachable at $AUTH_URL"
else
  areq POST /api/v1/auth/signup/request "{\"phone\":\"$(gen_phone)\"}"
  probe=$(jf status)
  if [ "$probe" = "otp_disabled" ]; then MODE="off"; elif [ "$probe" = "otp_sent" ]; then MODE="on"; else MODE="unknown"; fi
  record INFO "mint" "OTP mode (auth)" "" "" "MODE=$MODE (signup/request → '$probe')"
  if [ "$MODE" = "on" ]; then
    if support_reachable; then OTP_RECOVERY="support ($SUPPORT_URL)"
    elif command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$AUTH_CONTAINER"; then OTP_RECOVERY="docker-local"
    elif [ -n "$AUTH_SSH" ]; then OTP_RECOVERY="ssh"; else OTP_RECOVERY="none"; OTP_BLOCKED=1; fi
    [ "$OTP_BLOCKED" = "1" ] && record FAIL "mint" "OTP recovery available" "" "" "OTP ON but no recovery channel (set SUPPORT_URL / run on box / set AUTH_SSH)" \
      || record INFO "mint" "OTP recovery channel" "" "" "$OTP_RECOVERY"
  fi
  otp_ready() { [ "$MODE" = "off" ] || { [ "$MODE" = "on" ] && [ "$OTP_BLOCKED" = "0" ]; }; }
  if otp_ready; then
    mint_customer "$(gen_phone)" "Wallet C1"
    if [ "$MC_CODE" = "201" ]; then
      C1_ACCESS="$MC_ACCESS"; C1_ID="$MC_ID"
      record PASS "mint" "customer C1 minted (auth signup → 201)" "201" "201" "id=$C1_ID"
      req GET /api/v1/wallet/me "" "$C1_ACCESS"
      if [ "$RESP_CODE" = "200" ]; then TOKENS_OK=1; record PASS "mint" "wallet accepts auth-issued token (RS256 key aligned)" "200" "200" "key OK"
      elif [ "$RESP_CODE" = "401" ]; then TOKENS_OK=0
        record FAIL "mint" "wallet accepts auth-issued token" "401" "200" "wallet REJECTED a fresh auth token → JWT_PUBLIC_KEY_B64 drift vs auth. Copy auth's key into 10-wallet/env and restart. Authed sections skipped."
      else record WARN "mint" "wallet /me with fresh token" "$RESP_CODE" "200" "unexpected"; fi
    else record FAIL "mint" "customer C1 minted" "$MC_CODE" "201" "$(jf error.code)"; fi
  else record SKIP "mint" "customer minting" "" "201" "OTP recovery blocked"; fi
fi

# =============================================================================
section "4. /me auto-create + /me/entries + /me/topup"
# =============================================================================
if [ "$TOKENS_OK" = "1" ]; then
  req GET /api/v1/wallet/me "" "$C1_ACCESS"
  assert_code "me" "/me → 200 (auto-create)" "200" "$RESP_CODE"
  assert_eq "me" "  currency==BDT" "$(jf currency)" "BDT" "currency"
  assert_eq "me" "  status==active" "$(jf status)" "active" "status"
  assert_eq "me" "  fresh balance_minor==0" "$(jf balance_minor)" "0" "balance_minor"
  assert_eq "me" "  fresh version==0" "$(jf version)" "0" "version"

  req GET /api/v1/wallet/me/entries "" "$C1_ACCESS"
  assert_code "me" "/me/entries → 200 (empty array)" "200" "$RESP_CODE"

  # topup: missing Idempotency-Key → 400
  _http "$WALLET_URL" POST /api/v1/wallet/me/topup "{\"amount_minor\":5000}" "$C1_ACCESS"
  assert_code "topup" "topup missing Idempotency-Key → 400" "400" "$RESP_CODE"
  assert_eq "topup" "  code=missing_idempotency_key" "$(jf error.code)" "missing_idempotency_key" "code"
  # topup invalid amount → 422
  curl -s -S -m "$TIMEOUT" -o "$BODYF" -w '%{http_code}' -X POST -H "Authorization: Bearer $C1_ACCESS" \
    -H "Content-Type: application/json" -H "Idempotency-Key: ik-$(gen_uuid)" \
    --data '{"amount_minor":0}' "$WALLET_URL/api/v1/wallet/me/topup" > "$TMPD/tc" 2>/dev/null
  TC=$(cat "$TMPD/tc"); RESP_BODY=$(cat "$BODYF")
  assert_code "topup" "topup amount<=0 → 422" "422" "$TC"
  # topup valid → 201
  IK="ik-$(gen_uuid)"
  curl -s -S -m "$TIMEOUT" -o "$BODYF" -w '%{http_code}' -X POST -H "Authorization: Bearer $C1_ACCESS" \
    -H "Content-Type: application/json" -H "Idempotency-Key: $IK" \
    --data '{"amount_minor":25000}' "$WALLET_URL/api/v1/wallet/me/topup" > "$TMPD/tc" 2>/dev/null
  TC=$(cat "$TMPD/tc"); RESP_BODY=$(cat "$BODYF")
  assert_code "topup" "topup valid → 201" "201" "$TC"
  assert_eq "topup" "  balance_minor==25000" "$(jf balance_minor)" "25000" "balance_minor"
  # topup over cap → 409
  curl -s -S -m "$TIMEOUT" -o "$BODYF" -w '%{http_code}' -X POST -H "Authorization: Bearer $C1_ACCESS" \
    -H "Content-Type: application/json" -H "Idempotency-Key: ik-$(gen_uuid)" \
    --data '{"amount_minor":5000000}' "$WALLET_URL/api/v1/wallet/me/topup" > "$TMPD/tc" 2>/dev/null
  TC=$(cat "$TMPD/tc"); RESP_BODY=$(cat "$BODYF")
  assert_code "topup" "topup over 50k cap → 409" "409" "$TC"
  assert_eq "topup" "  code=wallet_max_exceeded" "$(jf error.code)" "wallet_max_exceeded" "code"
else record SKIP "me" "customer wallet suite" "" "" "no aligned C1 token"; fi

# =============================================================================
section "5. Public cashback rules"
# =============================================================================
req GET /api/v1/wallet/cashback-rules
assert_code "cashback" "GET /cashback-rules → 200 (public)" "200" "$RESP_CODE"
assert_nonempty "cashback" "  seeded rule present (rule[0].trigger)" "$(jf 0.trigger)" "trigger"
assert_eq "cashback" "  rule funded_by==platform" "$(jf 0.funded_by)" "platform" "funded_by"
assert_eq "cashback" "  rule reward_kind==percent_back" "$(jf 0.reward_kind)" "percent_back" "reward_kind"

# =============================================================================
section "6. Internal debit/credit/balance + ledger scenarios"
# =============================================================================
IU=$(gen_uuid)   # a fresh wallet user for internal scenarios
# bad uuid → 400
ireq GET /api/v1/wallet/balance/not-a-uuid
assert_code "internal" "balance bad uuid → 400" "400" "$RESP_CODE"
assert_eq "internal" "  code=bad_request" "$(jf error.code)" "bad_request" "code"
# balance auto-create → 200, balance 0
ireq GET "/api/v1/wallet/balance/$IU"
assert_code "internal" "balance new user → 200 (auto-create)" "200" "$RESP_CODE"
assert_eq "internal" "  balance_minor==0" "$(jf balance_minor)" "0" "balance_minor"
V0=$(jf version)

# idempotency_key too short → 422
ireq POST /api/v1/wallet/credit "{\"user_id\":\"$IU\",\"amount_minor\":1000,\"idempotency_key\":\"short\"}"
assert_code "internal" "credit short idempotency_key → 422" "422" "$RESP_CODE"
assert_eq "internal" "  code=invalid_request" "$(jf error.code)" "invalid_request" "code"

# CREDIT 100000 → balance up, version++
CK="cr-$(gen_uuid)"
ireq POST /api/v1/wallet/credit "{\"user_id\":\"$IU\",\"amount_minor\":100000,\"idempotency_key\":\"$CK\"}"
assert_code "ledger" "credit 100000 → 200" "200" "$RESP_CODE"
assert_eq "ledger" "  balance_minor==100000" "$(jf balance_minor)" "100000" "balance_minor"
V1=$(jf version)
[ -n "$V1" ] && [ "$V1" -gt "${V0:-0}" ] && record PASS "ledger" "credit bumps version ($V0→$V1)" "" "" "version++" \
  || record FAIL "ledger" "credit bumps version" "" "" "v0=$V0 v1=$V1"

# IDEMPOTENCY replay: same key → no double-move
ireq POST /api/v1/wallet/credit "{\"user_id\":\"$IU\",\"amount_minor\":100000,\"idempotency_key\":\"$CK\"}"
assert_code "ledger" "credit replay (same key) → 200" "200" "$RESP_CODE"
assert_eq "ledger" "  balance unchanged on replay" "$(jf balance_minor)" "100000" "balance_minor"

# DEBIT 40000 → balance down
DK="db-$(gen_uuid)"
ireq POST /api/v1/wallet/debit "{\"user_id\":\"$IU\",\"amount_minor\":40000,\"idempotency_key\":\"$DK\"}"
assert_code "ledger" "debit 40000 → 200" "200" "$RESP_CODE"
assert_eq "ledger" "  balance_minor==60000" "$(jf balance_minor)" "60000" "balance_minor"

# DEBIT replay → unchanged
ireq POST /api/v1/wallet/debit "{\"user_id\":\"$IU\",\"amount_minor\":40000,\"idempotency_key\":\"$DK\"}"
assert_code "ledger" "debit replay (same key) → 200" "200" "$RESP_CODE"
assert_eq "ledger" "  balance unchanged on replay" "$(jf balance_minor)" "60000" "balance_minor"

# OVERDRAW → 409 insufficient_balance
ireq POST /api/v1/wallet/debit "{\"user_id\":\"$IU\",\"amount_minor\":999999,\"idempotency_key\":\"od-$(gen_uuid)\"}"
assert_code "ledger" "overdraw → 409" "409" "$RESP_CODE"
assert_eq "ledger" "  code=insufficient_balance" "$(jf error.code)" "insufficient_balance" "code"

# CAP → 409 wallet_max_exceeded
ireq POST /api/v1/wallet/credit "{\"user_id\":\"$IU\",\"amount_minor\":5000000,\"idempotency_key\":\"cap-$(gen_uuid)\"}"
assert_code "ledger" "credit over cap → 409" "409" "$RESP_CODE"
assert_eq "ledger" "  code=wallet_max_exceeded" "$(jf error.code)" "wallet_max_exceeded" "code"

# read-back via balance
ireq GET "/api/v1/wallet/balance/$IU"
assert_eq "ledger" "balance read-back==60000" "$(jf balance_minor)" "60000" "balance_minor"

# =============================================================================
section "7. gRPC (optional — needs grpcurl)"
# =============================================================================
if command -v grpcurl >/dev/null 2>&1; then
  # with token → ok
  if grpcurl -plaintext -H "x-internal-token: $INTERNAL_SERVICE_TOKEN" \
      -d "{\"user_id\":\"$IU\"}" "$WALLET_GRPC" dokandar.wallet.v1.Wallet/GetBalance >"$TMPD/g" 2>"$TMPD/ge"; then
    record PASS "grpc" "Wallet.GetBalance with token → ok" "" "" "$(tr -d '\n' < "$TMPD/g" | cut -c1-80)"
  else record WARN "grpc" "Wallet.GetBalance with token" "" "" "$(cat "$TMPD/ge" | head -1)"; fi
  # without token → Unauthenticated
  if grpcurl -plaintext -d "{\"user_id\":\"$IU\"}" "$WALLET_GRPC" dokandar.wallet.v1.Wallet/GetBalance >"$TMPD/g" 2>"$TMPD/ge"; then
    record FAIL "grpc" "Wallet.GetBalance WITHOUT token → should be Unauthenticated" "" "" "call unexpectedly succeeded"
  else
    grep -qi 'Unauthenticated' "$TMPD/ge" && record PASS "grpc" "Wallet.GetBalance no token → Unauthenticated" "" "" "fail-closed" \
      || record WARN "grpc" "Wallet.GetBalance no token" "" "" "$(cat "$TMPD/ge" | head -1)"
  fi
else
  record SKIP "grpc" "gRPC checks" "" "" "grpcurl not installed (install to exercise :20010)"
fi

# EXIT trap writes result.json + sets the exit code
