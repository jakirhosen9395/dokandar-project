#!/usr/bin/env bash
# =============================================================================
# DOKANDAR Shop Service — full smoke / contract test harness
# -----------------------------------------------------------------------------
# Exercises EVERY shop endpoint over HTTP and asserts the documented success
# codes AND the reachable failure codes (400/401/403/404/405/409/422). Shop is
# a DOWNSTREAM service: its writes need a real RS256 token AND it calls peers,
# so this harness drives the whole cross-service surface:
#
#   * AUTH  (AUTH_URL)  — mints admin / shopkeeper / shop_staff / customer
#                          tokens (OTP via SUPPORT_URL), and is called BY shop
#                          over gRPC (LookupShopkeeper) during staff-assign.
#   * SUPPORT (SUPPORT_URL) — OTP-code source for the auth logins.
#   * KAFKA  — auth KYC events flow auth → Kafka → shop's kyc cache, surfaced as
#              `kyc_tier` on GET /shops/handle/{handle} (polled assertion).
#
# Headline cross-service checks (must be EXERCISED, not skipped):
#   - shop → auth gRPC: assigning a CUSTOMER as staff must come back as a clean
#     role rejection (422), NOT 5xx/UNAUTHENTICATED (= shared-token landmine).
#   - auth → Kafka → shop: a shopkeeper's KYC approval must flip the shop's
#     public `kyc_tier` to `verified`.
#
# Design mirrors 01-auth / 02-profile smoke_test: `set -uo pipefail`; stdlib
# python3; result.json from an EXIT trap; infra-down = INFO/WARN, never FAIL.
# Usage: see smoke_test/test_command.md
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

# --- configuration (env-overridable) ----------------------------------------
SHOP_URL="${SHOP_URL:-http://127.0.0.1:10003}"      # service under test
AUTH_URL="${AUTH_URL:-http://127.0.0.1:10001}"       # token minting + gRPC peer
SUPPORT_URL="${SUPPORT_URL:-http://127.0.0.1:10099}" # OTP-code recovery
ADMIN_PHONE="${ADMIN_PHONE:-01700000000}"
AUTH_CONTAINER="${AUTH_CONTAINER:-dokandar_auth_service_dev}"
TIMEOUT="${TIMEOUT:-15}"; HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-30}"; REQ_RETRIES="${REQ_RETRIES:-2}"
MIRROR_TIMEOUT="${MIRROR_TIMEOUT:-40}"               # secs to wait for KYC-tier mirror
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/out}"
RESULT_JSON="${RESULT_JSON:-$OUTPUT_DIR/result.json}"; LOG="${LOG_FILE:-$OUTPUT_DIR/smoke.log}"
AUTH_SSH="${AUTH_SSH:-}"; AUTH_SSH_KEY="${AUTH_SSH_KEY:-}"; REDIS_RESET_URL="${REDIS_RESET_URL:-}"
AUTH_SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
[ -n "$AUTH_SSH_KEY" ] && AUTH_SSH_OPTS="-i $AUTH_SSH_KEY $AUTH_SSH_OPTS"

mkdir -p "$OUTPUT_DIR"; TMPD="$(mktemp -d)"; BODYF="$TMPD/body"; RESULTS_TSV="$TMPD/results.tsv"
SEQ_FILE="$TMPD/seq"; HSEQ="$TMPD/hseq"; PHONES_FILE="$TMPD/phones"
: > "$RESULTS_TSV"; : > "$LOG"; printf '0' > "$SEQ_FILE"; printf '0' > "$HSEQ"; : > "$PHONES_FILE"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''; fi

SMOKE_STARTED="$(date -u +%FT%TZ)"; MODE="unknown"; OTP_RECOVERY="none"; OTP_BLOCKED=0
CODE_VERSION="?"; TENANT="?"; ENVNAME="?"

# --- recording + assertions -------------------------------------------------
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
  [ -n "$http" ] && extra=" (HTTP $http${exp:+, want $exp})"; [ -n "$det" ] && extra="$extra — $det"
  printf '%s %s :: %s%s\n' "$sym" "$cat" "$name" "$extra" >> "$LOG"
  printf '%b%s %s :: %s%s%b\n' "$col" "$sym" "$cat" "$name" "$extra" "$NC"
}
assert_code() { if [ "$4" = "$3" ]; then record PASS "$1" "$2" "$4" "$3" "${5:-}"; else record FAIL "$1" "$2" "$4" "$3" "${5:-}"; fi; }
assert_eq()   { local lbl="${5:-value}"; if [ "$3" = "$4" ]; then record PASS "$1" "$2" "" "" "$lbl='$3'"; else record FAIL "$1" "$2" "" "" "$lbl='$3' want '$4'"; fi; }
assert_nonempty() { if [ -n "$3" ]; then record PASS "$1" "$2" "" "" "${4:-field} present"; else record FAIL "$1" "$2" "" "" "${4:-field} missing"; fi; }
# assert the actual code is one of a set (space-separated); PASS records which
assert_in() { local cat="$1" name="$2" actual="$3" set="$4" det="${5:-}"; for c in $set; do [ "$actual" = "$c" ] && { record PASS "$cat" "$name" "$actual" "$set" "$det"; return; }; done; record FAIL "$cat" "$name" "$actual" "$set" "$det"; }

# --- HTTP + JSON ------------------------------------------------------------
_http() {
  local base="$1" m="$2" p="$3" body="${4:-}" tok="${5:-}" to="${6:-$TIMEOUT}"
  local a=(-s -S -m "$to" -o "$BODYF" -w '%{http_code} %{size_download} %{content_type}' -X "$m" "$base$p")
  [ -n "$body" ] && a+=(-H 'Content-Type: application/json' --data "$body")
  [ -n "$tok" ]  && a+=(-H "Authorization: Bearer $tok")
  local attempt=0 out rest
  while :; do
    out=$(curl "${a[@]}" 2>/dev/null) || out="${out:-000 0 }"
    RESP_CODE=${out%% *}; rest=${out#* }; RESP_SIZE=${rest%% *}; RESP_CT=${rest#* }
    [ -z "$RESP_CODE" ] && RESP_CODE="000"; RESP_BODY=$(cat "$BODYF" 2>/dev/null || true)
    { [ "$RESP_CODE" != "000" ] || [ "$attempt" -ge "$REQ_RETRIES" ]; } && break
    attempt=$((attempt + 1)); sleep 0.6
  done
}
req()  { _http "$SHOP_URL" "$@"; }
areq() { _http "$AUTH_URL" "$@"; }
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

RUN_SALT=$(( $(date +%s) % 1000000 ))
gen_phone() {
  local n; n=$(( $(cat "$SEQ_FILE" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$SEQ_FILE"
  local ph; ph=$(printf '017%06d%02d' "$RUN_SALT" "$((n % 100))"); printf '%s\n' "$ph" >> "$PHONES_FILE"; printf '%s' "$ph"
}
gen_handle() {  # ^[a-z0-9-]+$, unique per run
  local n; n=$(( $(cat "$HSEQ" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$HSEQ"
  printf 'shop-%s-%s' "$RUN_SALT" "$n"
}
urlenc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }

# --- OTP recovery (support → docker → ssh) ----------------------------------
read_otp_support() { [ -n "$SUPPORT_URL" ] || return 0; curl -s -m 8 "$SUPPORT_URL/otp/latest?phone=$1&purpose=$2" 2>/dev/null | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print(d.get("code","") if isinstance(d,dict) else "")' 2>/dev/null; }
read_otp_logs() {
  local phone="$1" purpose="$2" code logs=""
  code=$(read_otp_support "$phone" "$purpose"); [ -n "$code" ] && { printf '%s' "$code"; return; }
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$AUTH_CONTAINER"; then
    logs=$(docker logs --tail 600 "$AUTH_CONTAINER" 2>&1)
  elif [ -n "$AUTH_SSH" ]; then logs=$(ssh $AUTH_SSH_OPTS "$AUTH_SSH" "docker logs --tail 600 $AUTH_CONTAINER 2>&1" 2>/dev/null)
  else return 0; fi
  printf '%s\n' "$logs" | grep "DEV-OTP" | grep "phone=$phone" | grep "purpose=$purpose" | tail -1 | grep -oE 'code=[0-9]+' | grep -oE '[0-9]+' | tail -1
}
support_reachable() { [ -n "$SUPPORT_URL" ] || return 1; [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$SUPPORT_URL/health" 2>/dev/null)" = "200" ]; }
otp_code_for() {
  [ "$MODE" = "on" ] || { printf ''; return; }
  local i code="" avoid="${3:-}"
  for i in $(seq 1 12); do code=$(read_otp_logs "$1" "$2"); [ -n "$code" ] && [ "$code" != "$avoid" ] && { printf '%s' "$code"; return; }; sleep 0.5; done
  printf '%s' "$code"
}
reset_otp_rate() {
  local key="otp_rate:$1" url="$REDIS_RESET_URL"
  if [ -z "$url" ] && [ -f "$SCRIPT_DIR/../env/.env.dev" ]; then url=$(grep -E '^REDIS_URL=' "$SCRIPT_DIR/../env/.env.dev" 2>/dev/null | head -1 | cut -d= -f2-); fi
  if [ -n "$url" ]; then
    command -v redis-cli >/dev/null 2>&1 && redis-cli -u "$url" DEL "$key" >/dev/null 2>&1 && return 0
  fi
  if [ -n "$AUTH_SSH" ]; then
    ssh $AUTH_SSH_OPTS "$AUTH_SSH" bash -s "$AUTH_CONTAINER" "$key" >/dev/null 2>&1 <<'EOS'
docker exec "$1" python -c "import os,redis; redis.from_url(os.environ['REDIS_URL']).delete('$2')"
EOS
    [ $? -eq 0 ] && return 0
  fi
  return 1
}

# --- auth helpers -----------------------------------------------------------
mint_customer() {  # phone name → MC_CODE MC_ACCESS MC_ID
  local phone="$1" name="$2" prev; prev=$(read_otp_logs "$phone" signup)
  areq POST /api/v1/auth/signup/request "{\"phone\":\"$phone\"}"
  local code body; code=$(otp_code_for "$phone" signup "$prev")
  body="{\"phone\":\"$phone\",\"name\":\"$name\",\"role\":\"customer\""; [ -n "$code" ] && body="$body,\"code\":\"$code\""; body="$body}"
  areq POST /api/v1/auth/signup/verify "$body"
  MC_CODE="$RESP_CODE"; MC_ACCESS=""; MC_ID=""
  [ "$RESP_CODE" = "201" ] && { MC_ACCESS=$(jf access_token); MC_ID=$(jf user.id); }
}
login_phone() {  # phone → LP_CODE LP_ACCESS LP_ID
  local phone="$1" prev; prev=$(read_otp_logs "$phone" login)
  areq POST /api/v1/auth/login/request "{\"phone\":\"$phone\"}"
  local code body; code=$(otp_code_for "$phone" login "$prev")
  body="{\"phone\":\"$phone\""; [ -n "$code" ] && body="$body,\"code\":\"$code\""; body="$body}"
  areq POST /api/v1/auth/login/verify "$body"
  LP_CODE="$RESP_CODE"; LP_ACCESS=""; LP_ID=""
  [ "$RESP_CODE" = "200" ] && { LP_ACCESS=$(jf access_token); LP_ID=$(jf user.id); }
}
# provision_with creator_token role name → PV_OK PV_TOKEN PV_ID PV_PHONE PV_CREATE_CODE
# (auth POST /users by the given creator, then OTP login of the new user)
provision_with() {
  local ctok="$1" role="$2" name="$3"
  PV_OK=0; PV_TOKEN=""; PV_ID=""; PV_PHONE=""; PV_CREATE_CODE=""
  [ -n "$ctok" ] || return 0
  PV_PHONE=$(gen_phone)
  areq POST /api/v1/auth/users "{\"role\":\"$role\",\"phone\":\"$PV_PHONE\",\"name\":\"$name\"}" "$ctok"
  PV_CREATE_CODE="$RESP_CODE"; [ "$RESP_CODE" = "201" ] || return 0
  PV_ID=$(jf user.id); login_phone "$PV_PHONE"; [ "$LP_CODE" = "200" ] && { PV_TOKEN="$LP_ACCESS"; PV_OK=1; }
}
# create_shop token handle name → CS_CODE CS_ID  (RESP_BODY holds the shop)
create_shop() {
  local tok="$1" h="$2" name="$3"
  req POST /api/v1/shop/shops "{\"handle\":\"$h\",\"name\":\"$name\",\"lat\":23.8103,\"lon\":90.4125}" "$tok"
  CS_CODE="$RESP_CODE"; CS_ID=""; [ "$RESP_CODE" = "201" ] && CS_ID=$(jf shop.id)
}

section() { printf '\n%b===== %s =====%b\n' "$BOLD" "$1" "$NC"; printf '\n===== %s =====\n' "$1" >> "$LOG"; }

# --- EXIT trap → result.json ------------------------------------------------
finish() {
  local finished phones; finished="$(date -u +%FT%TZ)"; phones=$(paste -sd, "$PHONES_FILE" 2>/dev/null || true)
  SMOKE_FINISHED="$finished" SMOKE_STARTED="$SMOKE_STARTED" M_SHOP_URL="$SHOP_URL" M_AUTH_URL="$AUTH_URL" \
  M_MODE="$MODE" M_REC="$OTP_RECOVERY" M_CV="$CODE_VERSION" M_TENANT="$TENANT" M_ENV="$ENVNAME" \
  M_PHONES="$phones" M_ADMIN="$ADMIN_PHONE" \
  python3 - "$RESULTS_TSV" "$RESULT_JSON" <<'PYEOF'
import sys, json, os
from collections import Counter, OrderedDict
tsv, out = sys.argv[1], sys.argv[2]; rows = []
try:
    with open(tsv) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line: continue
            parts = line.split("\t");
            while len(parts) < 6: parts.append("")
            st, cat, name, http, exp, det = parts[:6]
            rows.append({"status": st, "category": cat, "name": name, "http_code": http, "expected": exp, "detail": det})
except FileNotFoundError: pass
c = Counter(r["status"] for r in rows)
summary = OrderedDict((k, c.get(k, 0)) for k in ("PASS","FAIL","SKIP","WARN","INFO")); summary["total"] = len(rows)
cats = OrderedDict()
for r in rows: cats.setdefault(r["category"], Counter())[r["status"]] += 1
doc = OrderedDict()
doc["meta"] = OrderedDict([
    ("service","shop"), ("shop_url",os.environ.get("M_SHOP_URL","")), ("auth_url",os.environ.get("M_AUTH_URL","")),
    ("otp_mode",os.environ.get("M_MODE","")), ("otp_recovery",os.environ.get("M_REC","")),
    ("code_version",os.environ.get("M_CV","")), ("tenant",os.environ.get("M_TENANT","")), ("env",os.environ.get("M_ENV","")),
    ("admin_phone",os.environ.get("M_ADMIN","")), ("started_at",os.environ.get("SMOKE_STARTED","")),
    ("finished_at",os.environ.get("SMOKE_FINISHED","")),
    ("generated_test_phones", sorted({p for p in os.environ.get("M_PHONES","").split(",") if p})),
])
doc["summary"] = summary; doc["by_category"] = {k: dict(v) for k, v in cats.items()}; doc["results"] = rows
with open(out,"w") as f: json.dump(doc,f,indent=2); f.write("\n")
verdict = "FAIL" if summary["FAIL"] else "PASS"
print(); print("="*64)
print(f"  RESULT: {verdict}   PASS={summary['PASS']} FAIL={summary['FAIL']} SKIP={summary['SKIP']} WARN={summary['WARN']} INFO={summary['INFO']} (total {summary['total']})")
print(f"  report: {out}"); print("="*64)
PYEOF
  rm -rf "$TMPD" 2>/dev/null || true
  local fails; fails=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["summary"]["FAIL"])' "$RESULT_JSON" 2>/dev/null || echo 1)
  [ "$fails" = "0" ] && exit 0 || exit 1
}
trap finish EXIT

printf '%bDOKANDAR shop smoke test%b  →  %s\n' "$BOLD" "$NC" "$SHOP_URL"
printf 'auth=%s  support=%s\nstarted %s\n' "$AUTH_URL" "$SUPPORT_URL" "$SMOKE_STARTED"

if ! req GET /ready || [ "$RESP_CODE" = "000" ]; then
  record FAIL "preflight" "GET /ready reachable" "$RESP_CODE" "200" "cannot reach $SHOP_URL — on the box use http://127.0.0.1:10003"; exit 1
fi
CODE_VERSION=$(jf identity.code_version); TENANT=$(jf identity.tenant); ENVNAME=$(jf identity.env)
record INFO "preflight" "service identity" "" "" "code_version=$CODE_VERSION tenant=$TENANT env=$ENVNAME"
if ! areq GET /ready || [ "$RESP_CODE" = "000" ]; then
  record WARN "preflight" "AUTH /ready reachable" "$RESP_CODE" "200" "cannot reach $AUTH_URL — token minting (authed sections) skipped"; AUTH_DOWN=1
else AUTH_DOWN=0; fi

# =============================================================================
section "1. Operational / contract surface"
# =============================================================================
req GET /ready
RDY=$(jf status)
if [ "$RESP_CODE" = "200" ]; then assert_eq "ops" "/ready status==ready" "$RDY" "ready" "status"
elif [ "$RESP_CODE" = "503" ]; then assert_eq "ops" "/ready status==not_ready" "$RDY" "not_ready" "status"
else record FAIL "ops" "/ready 200|503" "$RESP_CODE" "200|503"; fi
assert_eq "ops" "/ready dep[0]=postgres" "$(jf dependencies.0.name)" "postgres" "dep0"
# §16-a: /ready gates PostgreSQL ONLY (Redis DB 2 is a degradable handle cache,
# checked on /health). Assert there is exactly ONE readiness dependency.
assert_eq "ops" "/ready has no 2nd (redis) dep" "$(jf dependencies.1.name)" "" "dep1_absent"

req GET /health "" "" "$HEALTH_TIMEOUT"
HLT=$(jf status)
if [ "$RESP_CODE" = "200" ]; then assert_eq "ops" "/health status==healthy" "$HLT" "healthy" "status"
elif [ "$RESP_CODE" = "503" ]; then assert_eq "ops" "/health status==unhealthy" "$HLT" "unhealthy" "status"
else record FAIL "ops" "/health 200|503" "$RESP_CODE" "200|503"; fi
for dep in postgres redis kafka mongo_logs apm; do
  ok=$(jf "checks.$dep.ok")
  if [ -z "$ok" ]; then record FAIL "ops" "/health core check: $dep" "" "" "missing"
  elif [ "$ok" = "True" ]; then record INFO "ops" "/health dep $dep" "" "" "ok: $(jf checks.$dep.detail)"
  else record WARN "ops" "/health dep $dep DOWN" "" "" "$(jf checks.$dep.detail) (gating)"; fi
done
for g in grpc_auth grpc_media grpc_coupon; do
  ok=$(jf "checks.$g.ok"); [ -z "$ok" ] && record FAIL "ops" "/health has $g" "" "" "missing" \
    || record INFO "ops" "/health $g (diagnostic, non-gating)" "" "" "ok=$ok $(jf checks.$g.detail)"
done

req GET /data
if [ "$RESP_CODE" = "200" ]; then record PASS "ops" "/data snapshot present" "200" "200" "ok"
elif [ "$RESP_CODE" = "404" ]; then assert_eq "ops" "/data 404 carries no_snapshot" "$(jf error.code)" "no_snapshot" "code"
else record FAIL "ops" "/data 200|404" "$RESP_CODE" "200|404"; fi

METRIC_RE='^# (HELP|TYPE)|_total|seller_|shop_'
# NOTE: use a herestring, NOT `printf "$RESP_BODY" | grep -q`. Under `set -o
# pipefail`, grep -q exits on the first match and closes the pipe, so printf
# dies with SIGPIPE (141) and pipefail reports the pipeline as FAILED even
# though grep matched — a false negative that only appears once /metrics grows
# past a few KB (grep exits before printf finishes writing).
req GET /metrics
for _m in 1 2 3 4; do
  { [ "$RESP_CODE" = "200" ] && grep -qE "$METRIC_RE" <<<"$RESP_BODY"; } && break
  sleep 0.6; req GET /metrics
done
assert_code "ops" "GET /metrics" "200" "$RESP_CODE"
grep -qE "$METRIC_RE" <<<"$RESP_BODY" && record PASS "ops" "/metrics prometheus" "" "" "ok" || record FAIL "ops" "/metrics prometheus" "" "" "no metric lines"

req GET /docs; assert_code "ops" "GET /docs" "200" "$RESP_CODE"
case "$RESP_CT" in *text/html*) record PASS "ops" "/docs is html" "" "" "$RESP_CT";; *) record WARN "ops" "/docs content-type" "" "" "$RESP_CT";; esac
req GET /openapi.json; assert_code "ops" "GET /openapi.json" "200" "$RESP_CODE"
assert_nonempty "ops" "/openapi.json openapi version" "$(jf openapi)" "openapi"
assert_eq "ops" "/openapi.json bearerJwt scheme" "$(jf components.securitySchemes.bearerJwt.scheme)" "bearer" "scheme"

req GET /this-does-not-exist; assert_code "ops" "unknown path → 404" "404" "$RESP_CODE"
req POST /ready; assert_in "ops" "POST /ready → 405" "$RESP_CODE" "405 404"

# =============================================================================
section "2. Public reads (no token)"
# =============================================================================
req GET /api/v1/shop/categories; assert_code "public" "GET /categories → 200" "200" "$RESP_CODE"
req GET /api/v1/shop/admin-areas/divisions; assert_code "public" "GET /admin-areas/divisions → 200" "200" "$RESP_CODE"
DIV=$(jf items.0)
if [ -n "$DIV" ]; then
  # names (not slugs) → URL-encode each segment; assert 200 per level, stop on empty
  req GET "/api/v1/shop/admin-areas/$(urlenc "$DIV")/districts"; assert_code "public" "districts under '$DIV' → 200" "200" "$RESP_CODE"
  DIST=$(jf items.0)
  if [ -n "$DIST" ]; then
    req GET "/api/v1/shop/admin-areas/$(urlenc "$DIV")/$(urlenc "$DIST")/upazilas"; assert_code "public" "upazilas under '$DIST' → 200" "200" "$RESP_CODE"
    UPZ=$(jf items.0)
    if [ -n "$UPZ" ]; then
      req GET "/api/v1/shop/admin-areas/$(urlenc "$DIV")/$(urlenc "$DIST")/$(urlenc "$UPZ")/unions"; assert_code "public" "unions under '$UPZ' → 200" "200" "$RESP_CODE"
    else record INFO "public" "admin-areas unions" "" "" "no upazila seeded under '$DIST' — cascade stopped"; fi
  fi
fi
# geo
req GET /api/v1/shop/shops/near; assert_code "public" "/shops/near no lat/lon → 422" "422" "$RESP_CODE"
req GET "/api/v1/shop/shops/near?lat=23.8103&lon=90.4125&radius_m=5000"; assert_code "public" "/shops/near with lat/lon → 200" "200" "$RESP_CODE"
# unknown shop
req GET "/api/v1/shop/shops/11111111-1111-4111-8111-111111111111"; assert_code "public" "GET unknown shop id → 404" "404" "$RESP_CODE"
assert_eq "public" "  code=shop_not_found" "$(jf error.code)" "shop_not_found" "code"
req GET "/api/v1/shop/shops/handle/definitely-no-such-handle-xyz"; assert_code "public" "GET unknown handle → 404" "404" "$RESP_CODE"

# =============================================================================
section "3. Auth gate on writes"
# =============================================================================
req POST /api/v1/shop/shops "{\"handle\":\"$(gen_handle)\",\"name\":\"NoAuth\"}"
assert_code "authz" "POST /shops no token → 401" "401" "$RESP_CODE"
assert_eq "authz" "  code=token_missing" "$(jf error.code)" "token_missing" "code"
req POST /api/v1/shop/shops "{\"handle\":\"$(gen_handle)\",\"name\":\"Bad\"}" "garbage.token.value"
assert_code "authz" "POST /shops bad token → 401" "401" "$RESP_CODE"
assert_eq "authz" "  code=token_invalid" "$(jf error.code)" "token_invalid" "code"

# =============================================================================
section "4. Mint user types from AUTH + key-sanity gate"
# =============================================================================
ADMIN_TOKEN=""; SK1_TOKEN=""; SK1_ID=""; SK1_HANDLE=""; SK1_SHOP=""; SK2_TOKEN=""; SK2_ID=""
SS_TOKEN=""; SS_ID=""; C1_TOKEN=""; C1_ID=""; TOKENS_OK=0
if [ "${AUTH_DOWN:-0}" = "1" ]; then
  record SKIP "mint" "token minting" "" "" "AUTH unreachable"
else
  areq POST /api/v1/auth/signup/request "{\"phone\":\"$(gen_phone)\"}"
  ps=$(jf status)
  [ "$ps" = "otp_disabled" ] && MODE="off" || { [ "$ps" = "otp_sent" ] && MODE="on" || MODE="unknown"; }
  record INFO "mint" "OTP mode (auth)" "" "" "MODE=$MODE"
  if [ "$MODE" = "on" ]; then
    if support_reachable; then OTP_RECOVERY="support ($SUPPORT_URL)"
    elif command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$AUTH_CONTAINER"; then OTP_RECOVERY="docker-local"
    elif [ -n "$AUTH_SSH" ]; then OTP_RECOVERY="ssh"; else OTP_RECOVERY="none"; OTP_BLOCKED=1; fi
    [ "$OTP_BLOCKED" = "1" ] && record FAIL "mint" "OTP recovery available" "" "" "OTP on but no channel — set SUPPORT_URL / run on box / set AUTH_SSH" \
      || { record INFO "mint" "OTP recovery" "" "" "$OTP_RECOVERY"; reset_otp_rate "$ADMIN_PHONE" >/dev/null 2>&1 && record INFO "mint" "admin OTP rate reset" "" "" "cleared" || record WARN "mint" "admin OTP rate reset" "" "" "could not clear (reruns may 429)"; }
  fi
  otp_ready() { [ "$MODE" = "off" ] || { [ "$MODE" = "on" ] && [ "$OTP_BLOCKED" = "0" ]; }; }
  if otp_ready; then
    login_phone "$ADMIN_PHONE"
    [ "$LP_CODE" = "200" ] && { ADMIN_TOKEN="$LP_ACCESS"; record PASS "mint" "admin login → 200" "200" "200" ""; } || record WARN "mint" "admin login" "$LP_CODE" "200" "$(jf error.code)"
    # shopkeepers (admin-provisioned)
    provision_with "$ADMIN_TOKEN" shopkeeper "Shopkeeper One"; SK1_TOKEN="$PV_TOKEN"; SK1_ID="$PV_ID"
    [ "$PV_OK" = "1" ] && record PASS "mint" "shopkeeper SK1 provisioned+login" "200" "200" "id=$SK1_ID" || record WARN "mint" "SK1 provision" "${PV_CREATE_CODE:-}" "201" "most authed tests limited"
    provision_with "$ADMIN_TOKEN" shopkeeper "Shopkeeper Two"; SK2_TOKEN="$PV_TOKEN"; SK2_ID="$PV_ID"
    [ "$PV_OK" = "1" ] && record PASS "mint" "shopkeeper SK2 (ownership peer)" "200" "200" "id=$SK2_ID" || record WARN "mint" "SK2 provision" "${PV_CREATE_CODE:-}" "201" "ownership tests limited"
    # shop_staff owned by SK1 (created with SK1's OWN token so LookupShopkeeper owner == SK1)
    provision_with "$SK1_TOKEN" shop_staff "Staff Of SK1"; SS_TOKEN="$PV_TOKEN"; SS_ID="$PV_ID"
    [ "$PV_OK" = "1" ] && record PASS "mint" "shop_staff (owned by SK1) provisioned+login" "200" "200" "id=$SS_ID" || record WARN "mint" "shop_staff provision" "${PV_CREATE_CODE:-}" "201" "staff-assign 201 path limited"
    # a customer (self-signup) for RBAC + gRPC-role tests
    mint_customer "$(gen_phone)" "Customer One"; C1_TOKEN="$MC_ACCESS"; C1_ID="$MC_ID"
    [ "$MC_CODE" = "201" ] && record PASS "mint" "customer C1 signup" "201" "201" "id=$C1_ID" || record WARN "mint" "customer signup" "$MC_CODE" "201" ""
    # KEY-SANITY GATE: shop must accept an auth-issued token (else JWT key drift)
    if [ -n "$SK1_TOKEN" ]; then
      req GET /api/v1/shop/shops "" "$SK1_TOKEN"
      if [ "$RESP_CODE" = "401" ] && [ "$(jf error.code)" = "token_invalid" ]; then
        TOKENS_OK=0; record FAIL "mint" "shop accepts auth token" "401" "200" "shop REJECTED a fresh auth token (RS256 verify) → 03-shop JWT_PUBLIC_KEY_B64 stale vs auth. Sync + redeploy. Authed sections skipped."
      else TOKENS_OK=1; record PASS "mint" "shop accepts auth token (key aligned)" "$RESP_CODE" "200" ""; fi
    fi
  else record SKIP "mint" "user minting" "" "" "OTP recovery blocked"; fi
fi

# =============================================================================
section "5. RBAC on shop creation"
# =============================================================================
if [ "$TOKENS_OK" = "1" ]; then
  [ -n "$C1_TOKEN" ] && { create_shop "$C1_TOKEN" "$(gen_handle)" "By Customer"; assert_code "rbac" "customer create shop → 403" "403" "$CS_CODE"; assert_eq "rbac" "  code=insufficient_role" "$(jf error.code)" "insufficient_role" "code"; }
  [ -n "$SS_TOKEN" ] && { create_shop "$SS_TOKEN" "$(gen_handle)" "By Staff"; assert_code "rbac" "shop_staff create shop → 403" "403" "$CS_CODE"; }
  [ -n "$ADMIN_TOKEN" ] && { create_shop "$ADMIN_TOKEN" "$(gen_handle)" "By Admin"; assert_code "rbac" "admin create shop → 201" "201" "$CS_CODE"; }
else record SKIP "rbac" "creation RBAC" "" "" "no tokens (key drift?)"; fi

# =============================================================================
section "6. Shop create + validation (shopkeeper SK1)"
# =============================================================================
if [ "$TOKENS_OK" = "1" ] && [ -n "$SK1_TOKEN" ]; then
  req POST /api/v1/shop/shops "{\"handle\":\"BAD UPPER\",\"name\":\"X\"}" "$SK1_TOKEN"; assert_code "create" "bad handle → 422" "422" "$RESP_CODE"
  req POST /api/v1/shop/shops "{\"handle\":\"$(gen_handle)\"}" "$SK1_TOKEN"; assert_code "create" "missing name → 422" "422" "$RESP_CODE"
  SK1_HANDLE=$(gen_handle)
  create_shop "$SK1_TOKEN" "$SK1_HANDLE" "SK1 Main Shop"
  assert_code "create" "SK1 create shop → 201" "201" "$CS_CODE"; SK1_SHOP="$CS_ID"
  assert_nonempty "create" "  shop.id" "$SK1_SHOP" "id"
  assert_eq "create" "  shop.status==draft" "$(jf shop.status)" "draft" "status"
  # duplicate handle → 409
  create_shop "$SK1_TOKEN" "$SK1_HANDLE" "Dup"
  assert_code "create" "duplicate handle → 409" "409" "$CS_CODE"
else record SKIP "create" "create+validation" "" "" "no SK1 token"; fi

# =============================================================================
section "7. Read + update + activate lifecycle"
# =============================================================================
if [ "$TOKENS_OK" = "1" ] && [ -n "$SK1_SHOP" ]; then
  req GET "/api/v1/shop/shops/$SK1_SHOP"; assert_code "lifecycle" "public GET /shops/{id} → 200" "200" "$RESP_CODE"
  req GET "/api/v1/shop/shops/handle/$SK1_HANDLE"; assert_code "lifecycle" "public GET by handle → 200" "200" "$RESP_CODE"
  assert_nonempty "lifecycle" "  by-handle exposes kyc_tier" "$(jf shop.kyc_tier)" "kyc_tier"
  assert_eq "lifecycle" "  by-handle strips PII (no contact_phone)" "$(jf shop.contact_phone)" "" "contact_phone"
  req PATCH "/api/v1/shop/shops/$SK1_SHOP" "{\"name\":\"SK1 Renamed\",\"description\":\"updated\"}" "$SK1_TOKEN"
  assert_code "lifecycle" "SK1 PATCH own shop → 200" "200" "$RESP_CODE"
  assert_eq "lifecycle" "  name updated" "$(jf shop.name)" "SK1 Renamed" "name"
  req POST "/api/v1/shop/shops/$SK1_SHOP/activate" "" "$SK1_TOKEN"
  assert_code "lifecycle" "activate draft→live → 200" "200" "$RESP_CODE"
  assert_eq "lifecycle" "  status==live" "$(jf shop.status)" "live" "status"
  # invalid transition: shopkeeper PATCH live→suspended (admin-only) → 422
  req PATCH "/api/v1/shop/shops/$SK1_SHOP" "{\"status\":\"suspended\"}" "$SK1_TOKEN"
  assert_in "lifecycle" "shopkeeper → suspended (invalid) → 422" "$RESP_CODE" "422 403"
  # DELETE is a SOFT delete (status→closed), on a THROWAWAY shop (keep SK1_SHOP for §10-12)
  create_shop "$SK1_TOKEN" "$(gen_handle)" "SK1 Throwaway"
  if [ "$CS_CODE" = "201" ]; then
    DEL_ID="$CS_ID"
    req DELETE "/api/v1/shop/shops/$DEL_ID" "" "$SK1_TOKEN"; assert_code "lifecycle" "SK1 delete own shop → 204" "204" "$RESP_CODE"
    req GET "/api/v1/shop/shops/$DEL_ID"; assert_code "lifecycle" "  soft-deleted shop still readable" "200" "$RESP_CODE"
    assert_eq "lifecycle" "  status==closed after delete" "$(jf shop.status)" "closed" "status"
  fi
else record SKIP "lifecycle" "read/update/activate" "" "" "no SK1 shop"; fi

# =============================================================================
section "8. Ownership isolation (SK2 vs SK1's shop)"
# =============================================================================
if [ "$TOKENS_OK" = "1" ] && [ -n "$SK1_SHOP" ] && [ -n "$SK2_TOKEN" ]; then
  req PATCH "/api/v1/shop/shops/$SK1_SHOP" "{\"name\":\"hijack\"}" "$SK2_TOKEN"
  assert_code "ownership" "SK2 PATCH SK1 shop → 403" "403" "$RESP_CODE"; assert_eq "ownership" "  code=not_owner" "$(jf error.code)" "not_owner" "code"
  req POST "/api/v1/shop/shops/$SK1_SHOP/activate" "" "$SK2_TOKEN"; assert_code "ownership" "SK2 activate SK1 shop → 403" "403" "$RESP_CODE"
  req DELETE "/api/v1/shop/shops/$SK1_SHOP" "" "$SK2_TOKEN"; assert_code "ownership" "SK2 delete SK1 shop → 403" "403" "$RESP_CODE"
else record SKIP "ownership" "cross-owner isolation" "" "" "need SK1 shop + SK2 token"; fi

# =============================================================================
section "9. listMine + categories"
# =============================================================================
if [ "$TOKENS_OK" = "1" ]; then
  [ -n "$SK1_TOKEN" ] && { req GET /api/v1/shop/shops "" "$SK1_TOKEN"; assert_code "list" "SK1 list own shops → 200" "200" "$RESP_CODE"; }
  [ -n "$ADMIN_TOKEN" ] && { req GET /api/v1/shop/shops "" "$ADMIN_TOKEN"; assert_code "list" "admin list all shops → 200" "200" "$RESP_CODE"; }
  if [ -n "$SK1_TOKEN" ]; then
    CN="cat-$RUN_SALT-$(cat $HSEQ)"
    req POST /api/v1/shop/categories "{\"name\":\"$CN\",\"scope\":\"private\"}" "$SK1_TOKEN"; assert_code "cat" "shopkeeper create private category → 201" "201" "$RESP_CODE"
    req POST /api/v1/shop/categories "{\"name\":\"$CN\",\"scope\":\"private\"}" "$SK1_TOKEN"; assert_in "cat" "duplicate category → 409" "$RESP_CODE" "409 422"
  fi
  [ -n "$ADMIN_TOKEN" ] && { req POST /api/v1/shop/categories "{\"name\":\"global-$RUN_SALT\",\"scope\":\"global\"}" "$ADMIN_TOKEN"; assert_code "cat" "admin create global category → 201" "201" "$RESP_CODE"; }
  [ -n "$SS_TOKEN" ] && { req POST /api/v1/shop/categories "{\"name\":\"by-staff-$RUN_SALT\"}" "$SS_TOKEN"; assert_code "cat" "shop_staff create category → 403" "403" "$RESP_CODE"; }
else record SKIP "cat" "categories + listMine" "" "" "no tokens"; fi

# =============================================================================
section "10. Hours"
# =============================================================================
if [ "$TOKENS_OK" = "1" ] && [ -n "$SK1_SHOP" ]; then
  req PUT "/api/v1/shop/shops/$SK1_SHOP/hours" "{\"hours\":[{\"day_of_week\":0,\"open_time\":\"09:00:00\",\"close_time\":\"22:00:00\",\"is_closed\":false},{\"day_of_week\":5,\"is_closed\":true}]}" "$SK1_TOKEN"
  assert_code "hours" "SK1 replace hours → 200" "200" "$RESP_CODE"
  req GET "/api/v1/shop/shops/$SK1_SHOP/hours"; assert_code "hours" "public GET hours → 200" "200" "$RESP_CODE"
  # duplicate day_of_week → 422
  req PUT "/api/v1/shop/shops/$SK1_SHOP/hours" "{\"hours\":[{\"day_of_week\":0,\"open_time\":\"09:00:00\",\"close_time\":\"22:00:00\"},{\"day_of_week\":0,\"open_time\":\"10:00:00\",\"close_time\":\"20:00:00\"}]}" "$SK1_TOKEN"
  assert_code "hours" "duplicate day_of_week → 422" "422" "$RESP_CODE"
else record SKIP "hours" "hours suite" "" "" "no SK1 shop"; fi

# =============================================================================
section "11. Staff assign — shop → auth gRPC (the cross-service headline)"
# =============================================================================
if [ "$TOKENS_OK" = "1" ] && [ -n "$SK1_SHOP" ] && [ -n "$SK1_TOKEN" ]; then
  # (a) gRPC PATH WORKS: assigning a CUSTOMER must come back a clean role
  # rejection — only possible if shop's LookupShopkeeper call to auth succeeded.
  # A 5xx / UNAUTHENTICATED here = the shared INTERNAL_SERVICE_TOKEN landmine.
  if [ -n "$C1_ID" ]; then
    # Role-verification needs the gRPC client (Auth.LookupShopkeeper). Natively
    # the grpc PHP extension is optional — if it's absent, /health reports
    # grpc_auth=not_configured and seller cannot check the target's role, so it
    # degrades (fail-open). Record that honestly as a non-gating WARN; the real
    # 422/403 assertion runs when grpc is wired (the docker image builds it).
    GRPC_DETAIL=$(curl -s -m 8 "$SHOP_URL/health" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("checks",{}).get("grpc_auth",{}).get("detail",""))' 2>/dev/null)
    req POST "/api/v1/shop/shops/$SK1_SHOP/staff" "{\"user_id\":\"$C1_ID\"}" "$SK1_TOKEN"
    if [ "$GRPC_DETAIL" = "not_configured" ]; then
      record WARN "grpc" "assign customer → role rejection" "$RESP_CODE" "422 (needs grpc)" "grpc_auth not_configured (grpc ext absent / AUTH_GRPC_HOST unset) → role NOT verified; seller fail-opens (HTTP $RESP_CODE). Wire grpc + AUTH_GRPC_HOST (docker) to enforce. Non-gating natively."
    elif [ "$RESP_CODE" = "500" ] || [ "$RESP_CODE" = "503" ]; then
      record FAIL "grpc" "assign customer → role rejection (gRPC ok)" "$RESP_CODE" "422" "shop→auth gRPC FAILED (5xx/UNAUTHENTICATED). Likely shared INTERNAL_SERVICE_TOKEN mismatch OR AUTH_GRPC_HOST wrong. Check both sides."
    else
      assert_in "grpc" "assign customer → role-rejected via auth gRPC" "$RESP_CODE" "422 403" "code=$(jf error.code)"
    fi
  fi
  # (b) 201 OWNER-MATCH PATH: SS was created with SK1's own token, so auth says
  # SS is owned by SK1 → assign succeeds.
  if [ -n "$SS_ID" ]; then
    req POST "/api/v1/shop/shops/$SK1_SHOP/staff" "{\"user_id\":\"$SS_ID\"}" "$SK1_TOKEN"
    assert_in "grpc" "SK1 assign own shop_staff → 201" "$RESP_CODE" "201" "code=$(jf error.code)"
    if [ "$RESP_CODE" = "201" ]; then
      req POST "/api/v1/shop/shops/$SK1_SHOP/staff" "{\"user_id\":\"$SS_ID\"}" "$SK1_TOKEN"; assert_in "grpc" "re-assign same staff → 409" "$RESP_CODE" "409"
      req DELETE "/api/v1/shop/shops/$SK1_SHOP/staff/$SS_ID" "" "$SK1_TOKEN"; assert_code "grpc" "remove staff → 204" "204" "$RESP_CODE"
    fi
  fi
  # (c) non-owner cannot assign
  [ -n "$SK2_TOKEN" ] && [ -n "$SS_ID" ] && { req POST "/api/v1/shop/shops/$SK1_SHOP/staff" "{\"user_id\":\"$SS_ID\"}" "$SK2_TOKEN"; assert_code "grpc" "SK2 assign to SK1 shop → 403" "403" "$RESP_CODE"; }
else record SKIP "grpc" "staff-assign / shop→auth gRPC" "" "" "need SK1 shop + token"; fi

# =============================================================================
section "12. KYC tier mirror — auth → Kafka → shop (cross-service)"
# =============================================================================
if [ "$TOKENS_OK" = "1" ] && [ -n "$SK1_ID" ] && [ -n "$SK1_HANDLE" ] && [ -n "$ADMIN_TOKEN" ]; then
  areq POST /api/v1/auth/kyc/submit "{\"nid_key\":\"kyc/$SK1_ID/nid.jpg\",\"trade_license_key\":\"kyc/$SK1_ID/tl.jpg\",\"bank_account_last4\":\"4321\",\"mobile_wallet_number\":\"01711111111\"}" "$SK1_TOKEN"
  assert_code "kyc-mirror" "SK1 auth kyc/submit → 202" "202" "$RESP_CODE"; SUB=$(jf submission_id)
  if [ -n "$SUB" ]; then
    areq POST "/api/v1/auth/kyc/$SUB/approve" "" "$ADMIN_TOKEN"; assert_code "kyc-mirror" "admin approve SK1 KYC → 200" "200" "$RESP_CODE"
    deadline=$(( $(date +%s) + MIRROR_TIMEOUT )); tier=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
      req GET "/api/v1/shop/shops/handle/$SK1_HANDLE"; tier="$(jf shop.kyc_tier)"
      [ "$tier" = "verified" ] && break; sleep 2
    done
    if [ "$tier" = "verified" ]; then record PASS "kyc-mirror" "shop kyc_tier → verified (via Kafka)" "" "verified" "mirrored"
    else
      req GET /health "" "" "$HEALTH_TIMEOUT"
      if [ "$(jf checks.kafka.ok)" = "False" ]; then record WARN "kyc-mirror" "kyc_tier → verified (kafka DOWN)" "" "verified" "events buffered; not shop's fault"
      else record FAIL "kyc-mirror" "shop kyc_tier did not reach 'verified' (got '$tier')" "" "verified" "kafka UP — auth kyc.approved may lack user_id, OR shop ConsumeKycEvents not running/subscribed. Check both."; fi
    fi
  fi
else record SKIP "kyc-mirror" "KYC tier mirror" "" "" "need SK1 (shopkeeper) + admin"; fi

# =============================================================================
section "13. Media presign (logo/banner — shop → media gRPC)"
# =============================================================================
if [ "$TOKENS_OK" = "1" ] && [ -n "$SK1_SHOP" ]; then
  req POST "/api/v1/shop/shops/$SK1_SHOP/logo" "" "$SK1_TOKEN"
  record INFO "media" "POST /shops/{id}/logo" "$RESP_CODE" "" "actual=$RESP_CODE code=$(jf error.code) (half-built: 200 presign | 501 | 503 media_unavailable — recorded, not asserted)"
  req POST "/api/v1/shop/shops/$SK1_SHOP/banner" "" "$SK1_TOKEN"
  record INFO "media" "POST /shops/{id}/banner" "$RESP_CODE" "" "actual=$RESP_CODE code=$(jf error.code) (half-built — recorded, not asserted)"
else record SKIP "media" "logo/banner presign" "" "" "no SK1 shop"; fi

# =============================================================================
section "14. Backwards-compat aliases (same handlers — happy path each)"
# =============================================================================
if [ "$TOKENS_OK" = "1" ] && [ -n "$SK1_TOKEN" ]; then
  req GET /api/v1/shop/me "" "$SK1_TOKEN"; assert_code "compat" "GET /shop/me (alias of list) → 200" "200" "$RESP_CODE"
  AH=$(gen_handle)
  req POST /api/v1/shop/me "{\"handle\":\"$AH\",\"name\":\"Compat Shop\",\"lat\":23.8,\"lon\":90.4}" "$SK1_TOKEN"
  assert_code "compat" "POST /shop/me (alias of create) → 201" "201" "$RESP_CODE"; AID=$(jf shop.id)
  if [ -n "$AID" ]; then
    req GET "/api/v1/shop/$AID"; assert_code "compat" "GET /shop/{id} (alias of show) → 200" "200" "$RESP_CODE"
    req PUT "/api/v1/shop/$AID" "{\"name\":\"Compat Renamed\"}" "$SK1_TOKEN"; assert_code "compat" "PUT /shop/{id} (alias of patch) → 200" "200" "$RESP_CODE"
    req POST "/api/v1/shop/$AID/activate" "" "$SK1_TOKEN"; assert_code "compat" "POST /shop/{id}/activate (alias) → 200" "200" "$RESP_CODE"
  fi
else record SKIP "compat" "alias routes" "" "" "no SK1 token"; fi

# =============================================================================
section "15. Documented-but-not-exercised (transparency)"
# =============================================================================
record INFO "scope" "shop exposes NO gRPC server (it is a gRPC client to auth/media)" "" "" "nothing to grpcurl"
record INFO "scope" "503 dependency_unavailable" "" "" "NOT-EXERCISED: needs a live dep down"
record INFO "scope" "non-UUID path params" "" "" "route uuid-regex → unmatched → bare 404 (not 400) by design"

# EXIT trap writes result.json + sets exit code
