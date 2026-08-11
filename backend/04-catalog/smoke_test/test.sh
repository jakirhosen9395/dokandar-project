#!/usr/bin/env bash
# =============================================================================
# DOKANDAR 04-catalog — full smoke / contract test harness
# -----------------------------------------------------------------------------
# Exercises every catalog endpoint over HTTP + asserts documented success AND
# reachable failure codes (400/401/403/404/405/422). Catalog is a DOWNSTREAM
# verify-only service: writes need a real RS256 token minted from AUTH (OTP via
# SUPPORT). Headline cross-service checks (must be EXERCISED, not skipped):
#   - KEY SANITY: catalog must ACCEPT a fresh auth token (not 401 token_invalid)
#     — a 401 here = JWT_PUBLIC_KEY_B64 drift vs auth (the #1 fleet landmine).
#   - role gate: a CUSTOMER create → 403 insufficient_role (not 5xx/401).
#   - write path: a SHOPKEEPER create product → 201, then GET it back public.
# Mirrors 01-auth/02-profile/03-seller smoke: set -uo pipefail; stdlib python3;
# result.json from an EXIT trap; infra-down = INFO/WARN, never FAIL.
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

load_env_file() {
  local f="$1" line key val
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"; case "$line" in ''|\#*) continue ;; esac
    [[ "$line" == [A-Za-z_]*=* ]] || continue
    key="${line%%=*}"; [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [ -n "${!key:-}" ] && continue
    val="${line#*=}"
    if [[ "$val" =~ ^(.*[^[:space:]])[[:space:]]+#.* ]]; then val="${BASH_REMATCH[1]}"; fi
    val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    export "$key=$val"
  done < "$f"
}
load_env_file "$SCRIPT_DIR/.env"

CATALOG_URL="${CATALOG_URL:-http://127.0.0.1:10004}"
AUTH_URL="${AUTH_URL:-http://127.0.0.1:10001}"
SUPPORT_URL="${SUPPORT_URL:-http://127.0.0.1:10099}"
ADMIN_PHONE="${ADMIN_PHONE:-01700000000}"
AUTH_CONTAINER="${AUTH_CONTAINER:-dokandar_auth_service_dev}"
TIMEOUT="${TIMEOUT:-15}"; HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-30}"; REQ_RETRIES="${REQ_RETRIES:-2}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/out}"
RESULT_JSON="${RESULT_JSON:-$OUTPUT_DIR/result.json}"; LOG="${LOG_FILE:-$OUTPUT_DIR/smoke.log}"
AUTH_SSH="${AUTH_SSH:-}"; AUTH_SSH_KEY="${AUTH_SSH_KEY:-}"
AUTH_SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
[ -n "$AUTH_SSH_KEY" ] && AUTH_SSH_OPTS="-i $AUTH_SSH_KEY $AUTH_SSH_OPTS"

mkdir -p "$OUTPUT_DIR"; TMPD="$(mktemp -d)"; BODYF="$TMPD/body"; RESULTS_TSV="$TMPD/results.tsv"
SEQ_FILE="$TMPD/seq"; PHONES_FILE="$TMPD/phones"
: > "$RESULTS_TSV"; : > "$LOG"; printf '0' > "$SEQ_FILE"; : > "$PHONES_FILE"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''; fi

SMOKE_STARTED="$(date -u +%FT%TZ)"; MODE="unknown"; OTP_RECOVERY="none"; OTP_BLOCKED=0
CODE_VERSION="?"; TENANT="?"; ENVNAME="?"

record() {
  local st="$1" cat="$2" name="$3" http="${4:-}" exp="${5:-}" det="${6:-}"
  det=${det//$'\t'/ }; det=${det//$'\n'/ }
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$st" "$cat" "$name" "$http" "$exp" "$det" >> "$RESULTS_TSV"
  local sym col extra=""
  case "$st" in PASS) sym="[PASS]"; col=$GREEN;; FAIL) sym="[FAIL]"; col=$RED;; SKIP) sym="[SKIP]"; col=$YELLOW;; WARN) sym="[WARN]"; col=$YELLOW;; INFO) sym="[INFO]"; col=$BLUE;; *) sym="[????]"; col=$NC;; esac
  [ -n "$http" ] && extra=" (HTTP $http${exp:+, want $exp})"; [ -n "$det" ] && extra="$extra — $det"
  printf '%s %s :: %s%s\n' "$sym" "$cat" "$name" "$extra" >> "$LOG"
  printf '%b%s %s :: %s%s%b\n' "$col" "$sym" "$cat" "$name" "$extra" "$NC"
}
assert_code() { if [ "$4" = "$3" ]; then record PASS "$1" "$2" "$4" "$3" "${5:-}"; else record FAIL "$1" "$2" "$4" "$3" "${5:-}"; fi; }
assert_eq()   { local lbl="${5:-value}"; if [ "$3" = "$4" ]; then record PASS "$1" "$2" "" "" "$lbl='$3'"; else record FAIL "$1" "$2" "" "" "$lbl='$3' want '$4'"; fi; }
assert_nonempty() { if [ -n "$3" ]; then record PASS "$1" "$2" "" "" "${4:-field} present"; else record FAIL "$1" "$2" "" "" "${4:-field} missing"; fi; }
assert_in() { local cat="$1" name="$2" actual="$3" set="$4" det="${5:-}"; for c in $set; do [ "$actual" = "$c" ] && { record PASS "$cat" "$name" "$actual" "$set" "$det"; return; }; done; record FAIL "$cat" "$name" "$actual" "$set" "$det"; }

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
req()  { _http "$CATALOG_URL" "$@"; }
areq() { _http "$AUTH_URL" "$@"; }
jget() { python3 -c '
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
print("" if d is None else d)' "$1"; }
jf() { printf '%s' "$RESP_BODY" | jget "$1"; }

RUN_SALT=$(( $(date +%s) % 1000000 ))
gen_phone() { local n; n=$(( $(cat "$SEQ_FILE" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$SEQ_FILE"; local ph; ph=$(printf '017%06d%02d' "$RUN_SALT" "$((n % 100))"); printf '%s\n' "$ph" >> "$PHONES_FILE"; printf '%s' "$ph"; }

read_otp_support() { [ -n "$SUPPORT_URL" ] || return 0; curl -s -m 8 "$SUPPORT_URL/otp/latest?phone=$1&purpose=$2" 2>/dev/null | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print(d.get("code","") if isinstance(d,dict) else "")' 2>/dev/null; }
read_otp_logs() {
  local phone="$1" purpose="$2" code logs=""
  code=$(read_otp_support "$phone" "$purpose"); [ -n "$code" ] && { printf '%s' "$code"; return; }
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$AUTH_CONTAINER"; then logs=$(docker logs --tail 600 "$AUTH_CONTAINER" 2>&1)
  elif [ -n "$AUTH_SSH" ]; then logs=$(ssh $AUTH_SSH_OPTS "$AUTH_SSH" "docker logs --tail 600 $AUTH_CONTAINER 2>&1" 2>/dev/null); else return 0; fi
  printf '%s\n' "$logs" | grep "DEV-OTP" | grep "phone=$phone" | grep "purpose=$purpose" | tail -1 | grep -oE 'code=[0-9]+' | grep -oE '[0-9]+' | tail -1
}
support_reachable() { [ -n "$SUPPORT_URL" ] || return 1; [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$SUPPORT_URL/health" 2>/dev/null)" = "200" ]; }
otp_code_for() { [ "$MODE" = "on" ] || { printf ''; return; }; local i code="" avoid="${3:-}"; for i in $(seq 1 12); do code=$(read_otp_logs "$1" "$2"); [ -n "$code" ] && [ "$code" != "$avoid" ] && { printf '%s' "$code"; return; }; sleep 0.5; done; printf '%s' "$code"; }

mint_customer() {
  local phone="$1" name="$2" prev; prev=$(read_otp_logs "$phone" signup)
  areq POST /api/v1/auth/signup/request "{\"phone\":\"$phone\"}"
  local code body; code=$(otp_code_for "$phone" signup "$prev")
  body="{\"phone\":\"$phone\",\"name\":\"$name\",\"role\":\"customer\""; [ -n "$code" ] && body="$body,\"code\":\"$code\""; body="$body}"
  areq POST /api/v1/auth/signup/verify "$body"
  MC_CODE="$RESP_CODE"; MC_ACCESS=""; MC_ID=""
  [ "$RESP_CODE" = "201" ] && { MC_ACCESS=$(jf access_token); MC_ID=$(jf user.id); }
}
login_phone() {
  local phone="$1" prev; prev=$(read_otp_logs "$phone" login)
  areq POST /api/v1/auth/login/request "{\"phone\":\"$phone\"}"
  local code body; code=$(otp_code_for "$phone" login "$prev")
  body="{\"phone\":\"$phone\""; [ -n "$code" ] && body="$body,\"code\":\"$code\""; body="$body}"
  areq POST /api/v1/auth/login/verify "$body"
  LP_CODE="$RESP_CODE"; LP_ACCESS=""; LP_ID=""
  [ "$RESP_CODE" = "200" ] && { LP_ACCESS=$(jf access_token); LP_ID=$(jf user.id); }
}
provision_with() {
  local ctok="$1" role="$2" name="$3"
  PV_OK=0; PV_TOKEN=""; PV_ID=""; PV_PHONE=""; PV_CREATE_CODE=""
  [ -n "$ctok" ] || return 0
  PV_PHONE=$(gen_phone)
  areq POST /api/v1/auth/users "{\"role\":\"$role\",\"phone\":\"$PV_PHONE\",\"name\":\"$name\"}" "$ctok"
  PV_CREATE_CODE="$RESP_CODE"; [ "$RESP_CODE" = "201" ] || return 0
  PV_ID=$(jf user.id); login_phone "$PV_PHONE"; [ "$LP_CODE" = "200" ] && { PV_TOKEN="$LP_ACCESS"; PV_OK=1; }
}
section() { printf '\n%b===== %s =====%b\n' "$BOLD" "$1" "$NC"; printf '\n===== %s =====\n' "$1" >> "$LOG"; }

finish() {
  local finished phones; finished="$(date -u +%FT%TZ)"; phones=$(paste -sd, "$PHONES_FILE" 2>/dev/null || true)
  SMOKE_FINISHED="$finished" SMOKE_STARTED="$SMOKE_STARTED" M_URL="$CATALOG_URL" M_AUTH_URL="$AUTH_URL" \
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
            parts = line.split("\t")
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
    ("service","04-catalog"), ("catalog_url",os.environ.get("M_URL","")), ("auth_url",os.environ.get("M_AUTH_URL","")),
    ("otp_mode",os.environ.get("M_MODE","")), ("otp_recovery",os.environ.get("M_REC","")),
    ("code_version",os.environ.get("M_CV","")), ("tenant",os.environ.get("M_TENANT","")), ("env",os.environ.get("M_ENV","")),
    ("admin_phone",os.environ.get("M_ADMIN","")), ("started_at",os.environ.get("SMOKE_STARTED","")),
    ("finished_at",os.environ.get("SMOKE_FINISHED","")),
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

printf '%bDOKANDAR 04-catalog smoke test%b  →  %s\n' "$BOLD" "$NC" "$CATALOG_URL"
printf 'auth=%s  support=%s\nstarted %s\n' "$AUTH_URL" "$SUPPORT_URL" "$SMOKE_STARTED"

if ! req GET /ready || [ "$RESP_CODE" = "000" ]; then
  record FAIL "preflight" "GET /ready reachable" "$RESP_CODE" "200" "cannot reach $CATALOG_URL — on the box use http://127.0.0.1:10004"; exit 1
fi
CODE_VERSION=$(jf identity.code_version); TENANT=$(jf identity.tenant); ENVNAME=$(jf identity.env)
record INFO "preflight" "service identity" "" "" "code_version=$CODE_VERSION tenant=$TENANT env=$ENVNAME"
if ! areq GET /ready || [ "$RESP_CODE" = "000" ]; then
  record WARN "preflight" "AUTH /ready reachable" "$RESP_CODE" "200" "cannot reach $AUTH_URL — authed sections skipped"; AUTH_DOWN=1
else AUTH_DOWN=0; fi

# =============================================================================
section "1. Operational / contract surface"
# =============================================================================
req GET /ready; RDY=$(jf status)
if [ "$RESP_CODE" = "200" ]; then assert_eq "ops" "/ready status==ready" "$RDY" "ready" "status"
elif [ "$RESP_CODE" = "503" ]; then assert_eq "ops" "/ready status==not_ready" "$RDY" "not_ready" "status"
else record FAIL "ops" "/ready 200|503" "$RESP_CODE" "200|503"; fi
assert_eq "ops" "identity.service_name==04-catalog" "$(jf identity.service_name)" "04-catalog" "service_name"
assert_eq "ops" "/ready dep[0]=postgres" "$(jf dependencies.0.name)" "postgres" "dep0"
# §16-a: /ready gates PostgreSQL ONLY (Redis DB 3 is a degradable cache, on /health)
assert_eq "ops" "/ready has no 2nd (redis) dep" "$(jf dependencies.1.name)" "" "dep1_absent"

req GET /health "" "" "$HEALTH_TIMEOUT"; HLT=$(jf status)
if [ "$RESP_CODE" = "200" ]; then assert_eq "ops" "/health status==healthy" "$HLT" "healthy" "status"
elif [ "$RESP_CODE" = "503" ]; then assert_eq "ops" "/health status==unhealthy" "$HLT" "unhealthy" "status"
else record FAIL "ops" "/health 200|503" "$RESP_CODE" "200|503"; fi
for dep in postgres redis kafka mongo_logs apm; do
  ok=$(jf "checks.$dep.ok")
  if [ -z "$ok" ]; then record FAIL "ops" "/health core check: $dep" "" "" "missing"
  elif [ "$ok" = "True" ]; then record INFO "ops" "/health dep $dep" "" "" "ok: $(jf checks.$dep.detail)"
  else record WARN "ops" "/health dep $dep DOWN" "" "" "$(jf checks.$dep.detail) (gating)"; fi
done
ok=$(jf "checks.grpc_media.ok"); [ -z "$ok" ] && record FAIL "ops" "/health has grpc_media" "" "" "missing" \
  || record INFO "ops" "/health grpc_media (diagnostic, non-gating)" "" "" "ok=$ok $(jf checks.grpc_media.detail)"
assert_nonempty "ops" "/health observability.apm_service_name" "$(jf observability.apm_service_name)" "apm_service_name"

req GET /data
if [ "$RESP_CODE" = "200" ]; then record PASS "ops" "/data snapshot present" "200" "200" "ok"
elif [ "$RESP_CODE" = "404" ]; then assert_eq "ops" "/data 404 carries no_snapshot" "$(jf error.code)" "no_snapshot" "code"
else record FAIL "ops" "/data 200|404" "$RESP_CODE" "200|404"; fi

METRIC_RE='^# (HELP|TYPE)|_total|catalog_'
# herestring (NOT printf|grep -q): avoids the pipefail/SIGPIPE false-negative once /metrics grows past a few KB.
req GET /metrics
for _m in 1 2 3 4; do { [ "$RESP_CODE" = "200" ] && grep -qE "$METRIC_RE" <<<"$RESP_BODY"; } && break; sleep 0.6; req GET /metrics; done
assert_code "ops" "GET /metrics" "200" "$RESP_CODE"
grep -qE "$METRIC_RE" <<<"$RESP_BODY" && record PASS "ops" "/metrics prometheus" "" "" "ok" || record FAIL "ops" "/metrics prometheus" "" "" "no metric lines"
grep -qE 'catalog_outbox_pending' <<<"$RESP_BODY" && record PASS "ops" "/metrics has catalog_outbox_pending" "" "" "ok" || record WARN "ops" "/metrics outbox gauge" "" "" "missing"

req GET /openapi.json; assert_code "ops" "GET /openapi.json" "200" "$RESP_CODE"
assert_nonempty "ops" "/openapi.json openapi version" "$(jf openapi)" "openapi"
assert_eq "ops" "/openapi.json HTTPBearer scheme" "$(jf components.securitySchemes.HTTPBearer.scheme)" "bearer" "scheme"
req GET /docs "" "" "$TIMEOUT"; assert_in "ops" "GET /docs reachable (200|302 to swagger-ui)" "$RESP_CODE" "200 302"

# bare-404 on unmapped path: empty body + NO error envelope
BARE_CT=$(curl -s -o /dev/null -w '%{content_type}' "$CATALOG_URL/this-does-not-exist"); BARE_CODE=$(curl -s -o /dev/null -w '%{http_code}' "$CATALOG_URL/this-does-not-exist")
assert_code "ops" "unknown path → bare 404" "404" "$BARE_CODE"
[ -z "$BARE_CT" ] && record PASS "ops" "bare 404 has no Content-Type" "" "" "ok" || record WARN "ops" "bare 404 Content-Type" "" "" "got '$BARE_CT'"
req POST /ready; assert_in "ops" "POST /ready → 405|404" "$RESP_CODE" "405 404"

# =============================================================================
section "2. Public reads (no token)"
# =============================================================================
req GET /api/v1/catalog/products; assert_code "public" "GET /products → 200" "200" "$RESP_CODE"
req GET /api/v1/catalog/categories/tree; assert_code "public" "GET /categories/tree → 200" "200" "$RESP_CODE"
assert_nonempty "public" "/categories/tree has 'tree'" "$(printf '%s' "$RESP_BODY" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("yes" if "tree" in d else "")' 2>/dev/null)" "tree"
req GET "/api/v1/catalog/products/11111111-1111-4111-8111-111111111111"; assert_code "public" "GET unknown product → 404" "404" "$RESP_CODE"
assert_eq "public" "  code=not_found" "$(jf error.code)" "not_found" "code"
req GET "/api/v1/catalog/products/not-a-uuid"; assert_code "public" "GET malformed uuid → 400" "400" "$RESP_CODE"
assert_eq "public" "  code=invalid_uuid" "$(jf error.code)" "invalid_uuid" "code"

# =============================================================================
section "3. Auth gate on writes"
# =============================================================================
req POST /api/v1/catalog/products "{\"name_en\":\"X\",\"list_price_minor\":100}"
assert_code "authz" "POST /products no token → 401" "401" "$RESP_CODE"
assert_eq "authz" "  code=token_missing" "$(jf error.code)" "token_missing" "code"
req POST /api/v1/catalog/products "{\"name_en\":\"X\",\"list_price_minor\":100}" "garbage.token.value"
assert_code "authz" "POST /products bad token → 401" "401" "$RESP_CODE"
assert_eq "authz" "  code=token_invalid" "$(jf error.code)" "token_invalid" "code"

# =============================================================================
section "4. Mint tokens from AUTH + key-sanity gate"
# =============================================================================
ADMIN_TOKEN=""; SK1_TOKEN=""; SK1_ID=""; SK2_TOKEN=""; SK2_ID=""; C1_TOKEN=""; C1_ID=""; TOKENS_OK=0
if [ "${AUTH_DOWN:-0}" = "1" ]; then record SKIP "mint" "token minting" "" "" "AUTH unreachable"
else
  areq POST /api/v1/auth/signup/request "{\"phone\":\"$(gen_phone)\"}"; ps=$(jf status)
  [ "$ps" = "otp_disabled" ] && MODE="off" || { [ "$ps" = "otp_sent" ] && MODE="on" || MODE="unknown"; }
  record INFO "mint" "OTP mode (auth)" "" "" "MODE=$MODE"
  if [ "$MODE" = "on" ]; then
    if support_reachable; then OTP_RECOVERY="support ($SUPPORT_URL)"
    elif command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$AUTH_CONTAINER"; then OTP_RECOVERY="docker-local"
    elif [ -n "$AUTH_SSH" ]; then OTP_RECOVERY="ssh"; else OTP_RECOVERY="none"; OTP_BLOCKED=1; fi
    [ "$OTP_BLOCKED" = "1" ] && record FAIL "mint" "OTP recovery available" "" "" "OTP on but no channel" || record INFO "mint" "OTP recovery" "" "" "$OTP_RECOVERY"
  fi
  otp_ready() { [ "$MODE" = "off" ] || { [ "$MODE" = "on" ] && [ "$OTP_BLOCKED" = "0" ]; }; }
  if otp_ready; then
    login_phone "$ADMIN_PHONE"
    [ "$LP_CODE" = "200" ] && { ADMIN_TOKEN="$LP_ACCESS"; record PASS "mint" "admin login → 200" "200" "200" ""; } || record WARN "mint" "admin login" "$LP_CODE" "200" "$(jf error.code) (shopkeeper provisioning limited)"
    provision_with "$ADMIN_TOKEN" shopkeeper "Catalog Shopkeeper One"; SK1_TOKEN="$PV_TOKEN"; SK1_ID="$PV_ID"
    [ "$PV_OK" = "1" ] && record PASS "mint" "shopkeeper SK1 provisioned+login" "200" "200" "id=$SK1_ID" || record WARN "mint" "SK1 provision" "${PV_CREATE_CODE:-}" "201" "write-path tests limited"
    provision_with "$ADMIN_TOKEN" shopkeeper "Catalog Shopkeeper Two"; SK2_TOKEN="$PV_TOKEN"; SK2_ID="$PV_ID"
    [ "$PV_OK" = "1" ] && record PASS "mint" "shopkeeper SK2 (ownership peer)" "200" "200" "id=$SK2_ID" || record WARN "mint" "SK2 provision" "${PV_CREATE_CODE:-}" "201" "ownership tests limited"
    mint_customer "$(gen_phone)" "Catalog Customer One"; C1_TOKEN="$MC_ACCESS"; C1_ID="$MC_ID"
    [ "$MC_CODE" = "201" ] && record PASS "mint" "customer C1 signup" "201" "201" "id=$C1_ID" || record WARN "mint" "customer signup" "$MC_CODE" "201" ""
    # KEY-SANITY GATE: catalog must ACCEPT a fresh auth token on a protected route
    if [ -n "$SK1_TOKEN" ]; then
      req POST /api/v1/catalog/products "{\"name_en\":\"keycheck\",\"list_price_minor\":1,\"sharing_model\":\"shared\"}" "$SK1_TOKEN"
      if [ "$RESP_CODE" = "401" ] && [ "$(jf error.code)" = "token_invalid" ]; then
        TOKENS_OK=0; record FAIL "mint" "catalog accepts auth token" "401" "201" "catalog REJECTED a fresh auth token (RS256 verify) → 04-catalog JWT_PUBLIC_KEY_B64 stale vs auth. Sync + redeploy."
      else TOKENS_OK=1; record PASS "mint" "catalog accepts auth token (key aligned)" "$RESP_CODE" "201" ""; fi
    fi
  else record SKIP "mint" "token minting" "" "" "OTP gating unresolved"; fi
fi

# =============================================================================
section "5. Product / variant / stock / category write path (shopkeeper SK1)"
# =============================================================================
if [ "$TOKENS_OK" = "1" ] && [ -n "$SK1_TOKEN" ]; then
  req POST /api/v1/catalog/products "{\"name_en\":\"Premium Miniket Rice 5kg\",\"name_bn\":\"প্রিমিয়াম মিনিকেট চাল\",\"list_price_minor\":62000,\"sale_price_minor\":58000,\"sharing_model\":\"shared\",\"brand\":\"ACI\"}" "$SK1_TOKEN"
  assert_code "write" "create product → 201" "201" "$RESP_CODE"; PID=$(jf product.id)
  assert_eq "write" "  status=draft" "$(jf product.status)" "draft" "status"
  assert_nonempty "write" "  product.id" "$PID" "id"
  if [ -n "$PID" ]; then
    req GET "/api/v1/catalog/products/$PID"; assert_code "write" "GET product back (public) → 200" "200" "$RESP_CODE"
    assert_eq "write" "  name_en round-trips" "$(jf product.name_en)" "Premium Miniket Rice 5kg" "name_en"
    req PUT "/api/v1/catalog/products/$PID" "{\"status\":\"active\",\"brand\":\"ACI Pure\"}" "$SK1_TOKEN"; assert_code "write" "update product → 200" "200" "$RESP_CODE"
    req POST "/api/v1/catalog/products/$PID/variants" "{\"name_en\":\"5kg bag\",\"list_price_minor\":62000,\"attributes\":{\"weight\":\"5kg\"}}" "$SK1_TOKEN"
    assert_code "write" "add variant → 201" "201" "$RESP_CODE"; VID=$(jf variant.id)
    if [ -n "$VID" ]; then
      req PUT "/api/v1/catalog/stock/$VID" "{\"on_hand\":120,\"low_threshold\":10}" "$SK1_TOKEN"; assert_code "write" "set stock → 200" "200" "$RESP_CODE"
      assert_eq "write" "  on_hand=120" "$(jf on_hand)" "120" "on_hand"
    fi
    req POST "/api/v1/catalog/products/$PID/list-in-shop" "{\"shop_id\":\"22222222-2222-4222-8222-222222222222\"}" "$SK1_TOKEN"; assert_code "write" "list-in-shop → 201" "201" "$RESP_CODE"
  fi
  # category create
  req POST /api/v1/catalog/categories "{\"name_en\":\"Rice & Grains $RUN_SALT\",\"name_bn\":\"চাল\"}" "$SK1_TOKEN"; assert_code "write" "create category → 201" "201" "$RESP_CODE"
  # validation: missing both names → 422 at_least_one_required
  req POST /api/v1/catalog/products "{\"list_price_minor\":100}" "$SK1_TOKEN"; assert_code "validation" "no name → 422" "422" "$RESP_CODE"
  assert_eq "validation" "  code=validation_error" "$(jf error.code)" "validation_error" "code"
  # integer-minor overflow → 422 (boundary reject, never overflow INT4)
  req POST /api/v1/catalog/products "{\"name_en\":\"Overflow\",\"list_price_minor\":9999999999}" "$SK1_TOKEN"; assert_code "validation" "list_price > INT4 → 422" "422" "$RESP_CODE"
else record SKIP "write" "write path" "" "" "no shopkeeper token (mint gating)"; fi

# =============================================================================
section "6. RBAC + ownership"
# =============================================================================
if [ -n "$C1_TOKEN" ]; then
  req POST /api/v1/catalog/products "{\"name_en\":\"By Customer\",\"list_price_minor\":100,\"sharing_model\":\"shared\"}" "$C1_TOKEN"
  assert_code "rbac" "customer create product → 403" "403" "$RESP_CODE"
  assert_eq "rbac" "  code=insufficient_role" "$(jf error.code)" "insufficient_role" "code"
fi
if [ "$TOKENS_OK" = "1" ] && [ -n "${PID:-}" ] && [ -n "$SK2_TOKEN" ]; then
  req PUT "/api/v1/catalog/products/$PID" "{\"brand\":\"Hijack\"}" "$SK2_TOKEN"
  assert_code "rbac" "non-owner SK2 update SK1's product → 403" "403" "$RESP_CODE"
  assert_eq "rbac" "  code=forbidden" "$(jf error.code)" "forbidden" "code"
fi

# =============================================================================
section "7. gRPC east-west (Catalog @ 20004) — non-gating"
# =============================================================================
GRPC_HOSTPORT="${GRPC_HOSTPORT:-127.0.0.1:20004}"
if command -v grpcurl >/dev/null 2>&1; then
  ITOK=$(grep -E '^INTERNAL_SERVICE_TOKEN=' "$SCRIPT_DIR/../env/.env.dev" 2>/dev/null | head -1 | cut -d= -f2-)
  if [ -n "${VID:-}" ] && [ -n "$ITOK" ]; then
    PA=(-import-path "$SCRIPT_DIR/../proto" -proto catalog.proto)   # no server reflection → pass the proto
    OUT=$(grpcurl -plaintext "${PA[@]}" -H "x-internal-token: $ITOK" -d "{\"variant_id\":\"$VID\",\"quantity\":1}" "$GRPC_HOSTPORT" dokandar.catalog.v1.Catalog/CheckStock 2>&1)
    grep -q 'sufficient' <<<"$OUT" && record PASS "grpc" "CheckStock returns answer" "" "" "ok" || record WARN "grpc" "CheckStock" "" "" "$(printf '%s' "$OUT" | head -c 120)"
    # missing token → UNAUTHENTICATED
    OUT2=$(grpcurl -plaintext "${PA[@]}" -d "{\"variant_id\":\"$VID\",\"quantity\":1}" "$GRPC_HOSTPORT" dokandar.catalog.v1.Catalog/CheckStock 2>&1)
    grep -qiE 'Unauthenticated|x-internal-token' <<<"$OUT2" && record PASS "grpc" "CheckStock no token → UNAUTHENTICATED" "" "" "ok" || record WARN "grpc" "CheckStock no-token gate" "" "" "$(printf '%s' "$OUT2" | head -c 120)"
  else record INFO "grpc" "gRPC functional test" "" "" "skipped (no variant or token)"; fi
else
  (exec 3<>/dev/tcp/${GRPC_HOSTPORT/:/\/}) 2>/dev/null && record INFO "grpc" "gRPC port reachable (grpcurl absent)" "" "" "$GRPC_HOSTPORT open" || record WARN "grpc" "gRPC port" "" "" "$GRPC_HOSTPORT closed"
fi

record INFO "done" "smoke complete" "" "" "see $RESULT_JSON"
