#!/usr/bin/env bash
# =============================================================================
# DOKANDAR 05-search — full smoke / contract test harness
# -----------------------------------------------------------------------------
# Search is a CONSUME-ONLY read projection: most routes are PUBLIC reads (no
# token); only POST /admin/reindex needs an ADMIN token (minted from AUTH, OTP
# via SUPPORT). Headline cross-service check: the projectors consume 04-catalog's
# already-published dokandar.product.changed events, so GET /search/products must
# return > 0 items (the CQRS projection working). set -uo pipefail; result.json
# from an EXIT trap; infra-down = INFO/WARN, never FAIL.
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

SEARCH_URL="${SEARCH_URL:-http://127.0.0.1:10005}"
AUTH_URL="${AUTH_URL:-http://127.0.0.1:10001}"
SUPPORT_URL="${SUPPORT_URL:-http://127.0.0.1:10099}"
ADMIN_PHONE="${ADMIN_PHONE:-01700000000}"
AUTH_CONTAINER="${AUTH_CONTAINER:-dokandar_auth_service_dev}"
TIMEOUT="${TIMEOUT:-15}"; HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-30}"; REQ_RETRIES="${REQ_RETRIES:-2}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/out}"
RESULT_JSON="${RESULT_JSON:-$OUTPUT_DIR/result.json}"; LOG="${LOG_FILE:-$OUTPUT_DIR/smoke.log}"
mkdir -p "$OUTPUT_DIR"; TMPD="$(mktemp -d)"; BODYF="$TMPD/body"; RESULTS_TSV="$TMPD/results.tsv"
SEQ_FILE="$TMPD/seq"; PHONES_FILE="$TMPD/phones"; : > "$RESULTS_TSV"; : > "$LOG"; printf '0' > "$SEQ_FILE"; : > "$PHONES_FILE"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''; fi
SMOKE_STARTED="$(date -u +%FT%TZ)"; MODE="unknown"; CODE_VERSION="?"; TENANT="?"; ENVNAME="?"

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
req()  { _http "$SEARCH_URL" "$@"; }
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
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$AUTH_CONTAINER"; then logs=$(docker logs --tail 600 "$AUTH_CONTAINER" 2>&1); else return 0; fi
  printf '%s\n' "$logs" | grep "DEV-OTP" | grep "phone=$phone" | grep "purpose=$purpose" | tail -1 | grep -oE 'code=[0-9]+' | grep -oE '[0-9]+' | tail -1
}
otp_code_for() { [ "$MODE" = "on" ] || { printf ''; return; }; local i code="" avoid="${3:-}"; for i in $(seq 1 12); do code=$(read_otp_logs "$1" "$2"); [ -n "$code" ] && [ "$code" != "$avoid" ] && { printf '%s' "$code"; return; }; sleep 0.5; done; printf '%s' "$code"; }
login_phone() {
  local phone="$1" prev; prev=$(read_otp_logs "$phone" login)
  areq POST /api/v1/auth/login/request "{\"phone\":\"$phone\"}"
  local code body; code=$(otp_code_for "$phone" login "$prev")
  body="{\"phone\":\"$phone\""; [ -n "$code" ] && body="$body,\"code\":\"$code\""; body="$body}"
  areq POST /api/v1/auth/login/verify "$body"
  LP_CODE="$RESP_CODE"; LP_ACCESS=""; [ "$RESP_CODE" = "200" ] && LP_ACCESS=$(jf access_token)
}
mint_customer() {
  local phone="$1" prev; prev=$(read_otp_logs "$phone" signup)
  areq POST /api/v1/auth/signup/request "{\"phone\":\"$phone\"}"
  local code body; code=$(otp_code_for "$phone" signup "$prev")
  body="{\"phone\":\"$phone\",\"name\":\"Search Customer\",\"role\":\"customer\""; [ -n "$code" ] && body="$body,\"code\":\"$code\""; body="$body}"
  areq POST /api/v1/auth/signup/verify "$body"
  MC_CODE="$RESP_CODE"; MC_ACCESS=""; [ "$RESP_CODE" = "201" ] && MC_ACCESS=$(jf access_token)
}
section() { printf '\n%b===== %s =====%b\n' "$BOLD" "$1" "$NC"; printf '\n===== %s =====\n' "$1" >> "$LOG"; }

finish() {
  local finished; finished="$(date -u +%FT%TZ)"
  SMOKE_FINISHED="$finished" SMOKE_STARTED="$SMOKE_STARTED" M_URL="$SEARCH_URL" M_AUTH_URL="$AUTH_URL" \
  M_MODE="$MODE" M_CV="$CODE_VERSION" M_TENANT="$TENANT" M_ENV="$ENVNAME" \
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
doc["meta"] = OrderedDict([("service","05-search"), ("search_url",os.environ.get("M_URL","")), ("auth_url",os.environ.get("M_AUTH_URL","")),
    ("otp_mode",os.environ.get("M_MODE","")), ("code_version",os.environ.get("M_CV","")), ("tenant",os.environ.get("M_TENANT","")),
    ("env",os.environ.get("M_ENV","")), ("started_at",os.environ.get("SMOKE_STARTED","")), ("finished_at",os.environ.get("SMOKE_FINISHED",""))])
doc["summary"] = summary; doc["by_category"] = {k: dict(v) for k, v in cats.items()}; doc["results"] = rows
with open(out,"w") as f: json.dump(doc,f,indent=2); f.write("\n")
v = "FAIL" if summary["FAIL"] else "PASS"
print(); print("="*64)
print(f"  RESULT: {v}   PASS={summary['PASS']} FAIL={summary['FAIL']} SKIP={summary['SKIP']} WARN={summary['WARN']} INFO={summary['INFO']} (total {summary['total']})")
print(f"  report: {out}"); print("="*64)
PYEOF
  rm -rf "$TMPD" 2>/dev/null || true
  local fails; fails=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["summary"]["FAIL"])' "$RESULT_JSON" 2>/dev/null || echo 1)
  [ "$fails" = "0" ] && exit 0 || exit 1
}
trap finish EXIT

printf '%bDOKANDAR 05-search smoke test%b  →  %s\n' "$BOLD" "$NC" "$SEARCH_URL"
if ! req GET /ready || [ "$RESP_CODE" = "000" ]; then
  record FAIL "preflight" "GET /ready reachable" "$RESP_CODE" "200" "cannot reach $SEARCH_URL — on the box use http://127.0.0.1:10005"; exit 1
fi
CODE_VERSION=$(jf identity.code_version); TENANT=$(jf identity.tenant); ENVNAME=$(jf identity.env)
record INFO "preflight" "service identity" "" "" "code_version=$CODE_VERSION tenant=$TENANT env=$ENVNAME"
if ! areq GET /ready || [ "$RESP_CODE" = "000" ]; then record WARN "preflight" "AUTH reachable" "$RESP_CODE" "200" "admin section skipped"; AUTH_DOWN=1; else AUTH_DOWN=0; fi

# =============================================================================
section "1. Operational / contract surface"
# =============================================================================
req GET /ready; RDY=$(jf status)
if [ "$RESP_CODE" = "200" ]; then assert_eq "ops" "/ready status==ready" "$RDY" "ready" "status"
elif [ "$RESP_CODE" = "503" ]; then assert_eq "ops" "/ready status==not_ready" "$RDY" "not_ready" "status"
else record FAIL "ops" "/ready 200|503" "$RESP_CODE" "200|503"; fi
assert_eq "ops" "identity.service_name==05-search" "$(jf identity.service_name)" "05-search" "service_name"
assert_eq "ops" "/ready dep[0]=postgres" "$(jf dependencies.0.name)" "postgres" "dep0"
assert_eq "ops" "/ready postgres-only (no 2nd dep)" "$(jf dependencies.1.name)" "" "dep1_absent"

req GET /health "" "" "$HEALTH_TIMEOUT"; HLT=$(jf status)
assert_in "ops" "/health 200|503" "$RESP_CODE" "200 503"
for dep in postgres elasticsearch kafka mongo_logs apm; do
  ok=$(jf "checks.$dep.ok")
  [ -z "$ok" ] && record FAIL "ops" "/health has $dep" "" "" "missing" || record INFO "ops" "/health dep $dep" "" "" "ok=$ok $(jf checks.$dep.detail)"
done
record INFO "ops" "/health projection lag block" "" "" "$(jf projection.lag)"

req GET /data
if [ "$RESP_CODE" = "200" ]; then record PASS "ops" "/data snapshot present" "200" "200" "ok"
elif [ "$RESP_CODE" = "404" ]; then assert_eq "ops" "/data 404 no_snapshot" "$(jf error.code)" "no_snapshot" "code"
else record FAIL "ops" "/data 200|404" "$RESP_CODE" "200|404"; fi

METRIC_RE='^# (HELP|TYPE)|_total|search_'
req GET /metrics
for _m in 1 2 3 4; do { [ "$RESP_CODE" = "200" ] && grep -qE "$METRIC_RE" <<<"$RESP_BODY"; } && break; sleep 0.6; req GET /metrics; done
assert_code "ops" "GET /metrics" "200" "$RESP_CODE"
grep -qE "$METRIC_RE" <<<"$RESP_BODY" && record PASS "ops" "/metrics prometheus" "" "" "ok" || record FAIL "ops" "/metrics prometheus" "" "" "no metric lines"
grep -qE 'search_projection_lag_messages' <<<"$RESP_BODY" && record PASS "ops" "/metrics has projection_lag gauge" "" "" "ok" || record WARN "ops" "/metrics projection_lag" "" "" "missing"

req GET /openapi.json; assert_code "ops" "GET /openapi.json" "200" "$RESP_CODE"
assert_eq "ops" "/openapi.json bearerJwt scheme" "$(jf components.securitySchemes.bearerJwt.scheme)" "bearer" "scheme"
req GET /docs "" "" "$TIMEOUT"; assert_in "ops" "GET /docs reachable" "$RESP_CODE" "200 301 302 303"
BARE_CODE=$(curl -s -o /dev/null -w '%{http_code}' "$SEARCH_URL/this-does-not-exist"); BARE_CT=$(curl -s -o /dev/null -w '%{content_type}' "$SEARCH_URL/this-does-not-exist")
assert_code "ops" "unknown path → bare 404" "404" "$BARE_CODE"
[ -z "$BARE_CT" ] && record PASS "ops" "bare 404 has no Content-Type" "" "" "ok" || record WARN "ops" "bare 404 Content-Type" "" "" "got '$BARE_CT'"

# =============================================================================
section "2. Public search reads (no token)"
# =============================================================================
req GET "/api/v1/search/products"; assert_code "search" "GET /products → 200" "200" "$RESP_CODE"
PTOTAL=$(jf total)
record INFO "search" "products total (projected from catalog)" "" "" "total=$PTOTAL"
[ "${PTOTAL:-0}" -gt 0 ] 2>/dev/null && record PASS "xservice" "projection seeded from 04-catalog events" "" "" "products_view total=$PTOTAL" || record WARN "xservice" "projection empty" "" "" "no product.changed consumed yet (catalog idle?)"
req GET "/api/v1/search/products?q=rice&locale=en"; assert_code "search" "GET /products?q=rice → 200" "200" "$RESP_CODE"
assert_eq "search" "  facets.category present" "$(printf '%s' "$RESP_BODY" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("yes" if "category" in d.get("facets",{}) else "")' 2>/dev/null)" "yes" "facets"
req GET "/api/v1/search/products?locale=fr"; assert_code "validation" "invalid locale → 422" "422" "$RESP_CODE"
assert_eq "validation" "  code=invalid_request" "$(jf error.code)" "invalid_request" "code"
req GET "/api/v1/search/products?size=9999"; assert_code "validation" "size out of range → 422" "422" "$RESP_CODE"

req GET "/api/v1/search/autocomplete?q=ri"; assert_code "search" "GET /autocomplete → 200" "200" "$RESP_CODE"
req GET "/api/v1/search/autocomplete"; assert_code "validation" "autocomplete no q → 422" "422" "$RESP_CODE"

req GET "/api/v1/search/shops"; assert_code "validation" "shops no lat/lng → 422" "422" "$RESP_CODE"
assert_eq "validation" "  code=invalid_request" "$(jf error.code)" "invalid_request" "code"
req GET "/api/v1/search/shops?lat=23.8103&lng=90.4125&radius_km=10"; assert_code "search" "shops near-me → 200" "200" "$RESP_CODE"
req GET "/api/v1/search/shops?lat=999&lng=0"; assert_code "validation" "shops lat out of range → 422" "422" "$RESP_CODE"

req GET "/api/v1/search/trending"; assert_code "search" "GET /trending → 200" "200" "$RESP_CODE"
req GET "/api/v1/search/categories/tree"; assert_code "search" "GET /categories/tree → 200" "200" "$RESP_CODE"

# =============================================================================
section "3. Admin reindex auth gate"
# =============================================================================
req POST /api/v1/search/admin/reindex; assert_code "authz" "reindex no token → 401" "401" "$RESP_CODE"
assert_eq "authz" "  code=unauthorized" "$(jf error.code)" "unauthorized" "code"
req POST /api/v1/search/admin/reindex "" "garbage.token.value"; assert_code "authz" "reindex bad token → 401" "401" "$RESP_CODE"
if [ "${AUTH_DOWN:-0}" = "0" ]; then
  areq POST /api/v1/auth/signup/request "{\"phone\":\"$(gen_phone)\"}"; ps=$(jf status)
  [ "$ps" = "otp_disabled" ] && MODE="off" || { [ "$ps" = "otp_sent" ] && MODE="on" || MODE="unknown"; }
  record INFO "mint" "OTP mode" "" "" "MODE=$MODE"
  # customer (non-admin) → 403
  mint_customer "$(gen_phone)"; C1="$MC_ACCESS"
  if [ -n "$C1" ]; then req POST /api/v1/search/admin/reindex "" "$C1"; assert_code "authz" "customer reindex → 403" "403" "$RESP_CODE"; assert_eq "authz" "  code=forbidden" "$(jf error.code)" "forbidden" "code"; fi
  # admin → 202
  login_phone "$ADMIN_PHONE"; ADMIN="$LP_ACCESS"
  if [ -n "$ADMIN" ]; then
    req POST /api/v1/search/admin/reindex "" "$ADMIN"; assert_code "admin" "admin reindex → 202" "202" "$RESP_CODE"
    assert_eq "admin" "  job_id present" "$(printf '%s' "$RESP_BODY" | python3 -c 'import sys,json;print("yes" if json.load(sys.stdin).get("job_id") else "")' 2>/dev/null)" "yes" "job_id"
  else record WARN "admin" "admin login" "$LP_CODE" "200" "admin reindex 202 path skipped"; fi
else record SKIP "authz" "admin reindex authed paths" "" "" "AUTH down"; fi

record INFO "done" "smoke complete" "" "" "see $RESULT_JSON"
