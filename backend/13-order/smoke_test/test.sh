#!/usr/bin/env bash
# =============================================================================
# DOKANDAR 13-order — full smoke / contract test harness
# -----------------------------------------------------------------------------
# 13-order is the checkout-saga orchestrator + order/sub-order system of record.
# It is a DOWNSTREAM verify-only service: any write needs a real RS256 token
# minted from AUTH (OTP recovered via SUPPORT). Sections:
#   1. Ops surface (STRICT): /ready (postgres-only), /health (pg+redis+kafka+
#      temporal+grpc_* diag+mongo_logs+apm+observability), /data, /metrics
#      (order_* incl order_outbox_pending), /openapi.json+/docs, bare-404.
#   2. Auth + idempotency gate (STRICT): POST /orders no Idempotency-Key → 400
#      missing_idempotency_key; POST /orders no token → 401.
#   3. Saga happy path (LENIENT): POST /orders WITH Idempotency-Key — 201|422 are
#      BOTH acceptable (a 422 stock_changed/coupon_invalid is the EXPECTED outcome
#      with no seeded catalog stock / wallet balance, NOT a smoke failure). If 201,
#      assert order_id + idempotent replay (same key → 200, same order_id).
#   4. GET /orders/me → 200.
#   5. gRPC (if grpcurl): Order.HasPurchased with x-internal-token → ok; without → Unauthenticated.
# KEY SANITY: order must ACCEPT a fresh auth token (a 401 minting one = JWT_PUBLIC_KEY_B64
# drift vs auth — the #1 fleet landmine). Mirrors 01/02/03/04 smoke: set -uo pipefail,
# stdlib python3, result.json from an EXIT trap, infra-down = INFO/WARN not FAIL.
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

ORDER_URL="${ORDER_URL:-http://127.0.0.1:10013}"
AUTH_URL="${AUTH_URL:-http://127.0.0.1:10001}"
SUPPORT_URL="${SUPPORT_URL:-http://127.0.0.1:10099}"
ADMIN_PHONE="${ADMIN_PHONE:-01700000000}"
AUTH_CONTAINER="${AUTH_CONTAINER:-dokandar_auth_service_dev}"
GRPC_HOSTPORT="${GRPC_HOSTPORT:-127.0.0.1:20013}"
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

SMOKE_STARTED="$(date -u +%FT%TZ)"; MODE="unknown"; OTP_RECOVERY="none"
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
  local base="$1" m="$2" p="$3" body="${4:-}" tok="${5:-}" to="${6:-$TIMEOUT}" extra="${7:-}"
  local a=(-s -S -m "$to" -o "$BODYF" -w '%{http_code} %{size_download} %{content_type}' -X "$m" "$base$p")
  [ -n "$body" ] && a+=(-H 'Content-Type: application/json' --data "$body")
  [ -n "$tok" ]  && a+=(-H "Authorization: Bearer $tok")
  [ -n "$extra" ] && a+=(-H "$extra")
  local attempt=0 out rest
  while :; do
    out=$(curl "${a[@]}" 2>/dev/null) || out="${out:-000 0 }"
    RESP_CODE=${out%% *}; rest=${out#* }; RESP_SIZE=${rest%% *}; RESP_CT=${rest#* }
    [ -z "$RESP_CODE" ] && RESP_CODE="000"; RESP_BODY=$(cat "$BODYF" 2>/dev/null || true)
    { [ "$RESP_CODE" != "000" ] || [ "$attempt" -ge "$REQ_RETRIES" ]; } && break
    attempt=$((attempt + 1)); sleep 0.6
  done
}
req()  { _http "$ORDER_URL" "$@"; }
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
otp_code_for() { [ "$MODE" = "on" ] || { printf ''; return; }; local i code="" avoid="${3:-}"; for i in $(seq 1 6); do code=$(read_otp_logs "$1" "$2"); [ -n "$code" ] && [ "$code" != "$avoid" ] && { printf '%s' "$code"; return; }; sleep 1; done; printf '%s' "$code"; }

mint_customer() {
  local phone="$1" name="$2" prev; prev=$(read_otp_logs "$phone" signup)
  areq POST /api/v1/auth/signup/request "{\"phone\":\"$phone\"}"
  local code body; code=$(otp_code_for "$phone" signup "$prev")
  body="{\"phone\":\"$phone\",\"name\":\"$name\",\"role\":\"customer\""; [ -n "$code" ] && body="$body,\"code\":\"$code\""; body="$body}"
  areq POST /api/v1/auth/signup/verify "$body"
  MC_CODE="$RESP_CODE"; MC_ACCESS=""; MC_ID=""
  [ "$RESP_CODE" = "201" ] && { MC_ACCESS=$(jf access_token); MC_ID=$(jf user.id); }
}
section() { printf '\n%b===== %s =====%b\n' "$BOLD" "$1" "$NC"; printf '\n===== %s =====\n' "$1" >> "$LOG"; }

finish() {
  local finished phones; finished="$(date -u +%FT%TZ)"; phones=$(paste -sd, "$PHONES_FILE" 2>/dev/null || true)
  SMOKE_FINISHED="$finished" SMOKE_STARTED="$SMOKE_STARTED" M_URL="$ORDER_URL" M_AUTH_URL="$AUTH_URL" \
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
    ("service","13-order"), ("order_url",os.environ.get("M_URL","")), ("auth_url",os.environ.get("M_AUTH_URL","")),
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

printf '%bDOKANDAR 13-order smoke test%b  →  %s\n' "$BOLD" "$NC" "$ORDER_URL"
printf 'auth=%s  support=%s\nstarted %s\n' "$AUTH_URL" "$SUPPORT_URL" "$SMOKE_STARTED"

if ! req GET /ready || [ "$RESP_CODE" = "000" ]; then
  record FAIL "preflight" "GET /ready reachable" "$RESP_CODE" "200" "cannot reach $ORDER_URL — on the box use http://127.0.0.1:10013"; exit 1
fi
CODE_VERSION=$(jf identity.code_version); TENANT=$(jf identity.tenant); ENVNAME=$(jf identity.env)
record INFO "preflight" "service identity" "" "" "code_version=$CODE_VERSION tenant=$TENANT env=$ENVNAME"
if ! areq GET /ready || [ "$RESP_CODE" = "000" ]; then
  record WARN "preflight" "AUTH /ready reachable" "$RESP_CODE" "200" "cannot reach $AUTH_URL — authed sections skipped"; AUTH_DOWN=1
else AUTH_DOWN=0; fi
# OTP recovery mode: support reachable OR auth container visible → MODE=on
if [ -n "$SUPPORT_URL" ] && [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$SUPPORT_URL/health" 2>/dev/null)" = "200" ]; then
  MODE="on"; OTP_RECOVERY="support"
elif command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$AUTH_CONTAINER"; then
  MODE="on"; OTP_RECOVERY="docker-logs"
else MODE="off"; OTP_RECOVERY="none"; fi
record INFO "preflight" "OTP recovery" "" "" "mode=$MODE via=$OTP_RECOVERY"

# =============================================================================
section "1. Operational / contract surface"
# =============================================================================
req GET /ready; RDY=$(jf status)
if [ "$RESP_CODE" = "200" ]; then assert_eq "ops" "/ready status==ready" "$RDY" "ready" "status"
elif [ "$RESP_CODE" = "503" ]; then assert_eq "ops" "/ready status==not_ready" "$RDY" "not_ready" "status"
else record FAIL "ops" "/ready 200|503" "$RESP_CODE" "200|503"; fi
assert_eq "ops" "identity.service_name==13-order" "$(jf identity.service_name)" "13-order" "service_name"
# §8: /ready gates POSTGRES ONLY (Temporal/Redis/Kafka/gRPC peers are degradable → /health)
assert_eq "ops" "/ready dep[0]=postgres" "$(jf dependencies.0.name)" "postgres" "dep0"
assert_eq "ops" "/ready has no 2nd dep (postgres-only)" "$(jf dependencies.1.name)" "" "dep1_absent"

req GET /health "" "" "$HEALTH_TIMEOUT"; HLT=$(jf status)
if [ "$RESP_CODE" = "200" ]; then assert_eq "ops" "/health status==healthy" "$HLT" "healthy" "status"
elif [ "$RESP_CODE" = "503" ]; then assert_eq "ops" "/health status==unhealthy" "$HLT" "unhealthy" "status"
else record FAIL "ops" "/health 200|503" "$RESP_CODE" "200|503"; fi
# Gating deps must be PRESENT (down → WARN, not FAIL: infra may be partial in a smoke env)
for dep in postgres redis kafka mongo_logs apm; do
  ok=$(jf "checks.$dep.ok")
  if [ -z "$ok" ]; then record FAIL "ops" "/health core check: $dep" "" "" "missing"
  elif [ "$ok" = "True" ]; then record INFO "ops" "/health dep $dep" "" "" "ok: $(jf checks.$dep.detail)"
  else record WARN "ops" "/health dep $dep DOWN" "" "" "$(jf checks.$dep.detail) (gating)"; fi
done
# Diagnostic-only checks must EXIST but never gate (temporal + the three gRPC peers)
for dep in temporal grpc_catalog grpc_coupon grpc_wallet; do
  ok=$(jf "checks.$dep.ok")
  if [ -z "$ok" ]; then record FAIL "ops" "/health has $dep (diagnostic)" "" "" "missing"
  else record INFO "ops" "/health $dep (diagnostic, non-gating)" "" "" "ok=$ok $(jf checks.$dep.detail)"; fi
done
assert_nonempty "ops" "/health observability.apm_service_name" "$(jf observability.apm_service_name)" "apm_service_name"
# ES log sink is exposed under observability.logs_sink_es (no checks.elasticsearch gate) — INFO
record INFO "ops" "/health observability.logs_sink_es" "" "" "$(jf observability.logs_sink_es)"

req GET /data; DCODE="$RESP_CODE"
if [ "$DCODE" = "200" ]; then
  assert_eq "ops" "/data identity.service_name" "$(jf identity.service_name)" "13-order" "service_name"
elif [ "$DCODE" = "404" ]; then
  assert_eq "ops" "/data 404 no_snapshot" "$(jf error.code)" "no_snapshot" "code"
else record WARN "ops" "/data 200|404" "$DCODE" "200|404" "unexpected"; fi

req GET /metrics
if [ "$RESP_CODE" = "200" ]; then
  for m in order_outbox_pending order_orders_placed_total order_orders_confirmed_total; do
    grep -q "$m" "$BODYF" && record PASS "ops" "/metrics has $m" "" "" "present" || record FAIL "ops" "/metrics has $m" "" "" "missing"
  done
  grep -q 'service="13-order"' "$BODYF" && record PASS "ops" "/metrics service label" "" "" "service=13-order" || record WARN "ops" "/metrics service label" "" "" "label absent"
else record FAIL "ops" "/metrics 200" "$RESP_CODE" "200"; fi

req GET /openapi.json; assert_code "ops" "/openapi.json 200" "200" "$RESP_CODE"
[ "$RESP_CODE" = "200" ] && assert_nonempty "ops" "/openapi.json info.version" "$(jf info.version)" "info.version"
req GET /docs; assert_in "ops" "/docs reachable" "$RESP_CODE" "200 302" "swagger-ui"

# bare-404 on an unmapped path: Content-Length 0, no body
req GET /api/v1/order/__nope__
if [ "$RESP_CODE" = "404" ] && [ "${RESP_SIZE:-0}" = "0" ]; then record PASS "ops" "bare-404 Content-Length:0" "404" "404" "size=0"
else record FAIL "ops" "bare-404 Content-Length:0" "$RESP_CODE" "404" "size=${RESP_SIZE:-?}"; fi

# =============================================================================
section "2. Auth + idempotency gate (STRICT)"
# =============================================================================
ITEMS_OK='{"items":[{"shop_id":"11111111-1111-1111-1111-111111111111","product_id":"22222222-2222-2222-2222-222222222222","variant_id":"33333333-3333-3333-3333-333333333333","quantity":1,"unit_price_minor":10000}],"payment_method":"cod"}'

# no token → 401 (auth checked BEFORE the idempotency-key check)
req POST /api/v1/order/orders "$ITEMS_OK"
assert_code "auth" "POST /orders no token → 401" "401" "$RESP_CODE"

CUST_TOK=""; CUST_ID=""
if [ "${AUTH_DOWN:-1}" = "0" ] && [ "$MODE" = "on" ]; then
  CPHONE=$(gen_phone); mint_customer "$CPHONE" "Order Smoke Cust"
  if [ "$MC_CODE" = "201" ] && [ -n "$MC_ACCESS" ]; then
    CUST_TOK="$MC_ACCESS"; CUST_ID="$MC_ID"
    record PASS "auth" "mint customer token (key-sanity)" "201" "201" "id=$CUST_ID"
  else record WARN "auth" "mint customer token" "$MC_CODE" "201" "OTP/signup unavailable — authed checks limited"; fi
else record INFO "auth" "mint customer token" "" "" "skipped (auth down or OTP mode off)"; fi

# WITH a valid token but NO Idempotency-Key → 400 missing_idempotency_key (the strict gate)
if [ -n "$CUST_TOK" ]; then
  req POST /api/v1/order/orders "$ITEMS_OK" "$CUST_TOK"
  assert_code "auth" "POST /orders no Idempotency-Key → 400" "400" "$RESP_CODE"
  assert_eq "auth" "missing_idempotency_key code" "$(jf error.code)" "missing_idempotency_key" "code"
  # KEY SANITY: a fresh auth token must NOT be rejected as invalid (401 token_invalid = JWT key drift)
  [ "$RESP_CODE" = "401" ] && record FAIL "auth" "fresh token accepted (no JWT key drift)" "401" "!=401" "JWT_PUBLIC_KEY_B64 drift vs auth!" \
    || record PASS "auth" "fresh token accepted (no JWT key drift)" "$RESP_CODE" "!=401" "ok"
else record SKIP "auth" "POST /orders 400 missing_idempotency_key" "" "" "no customer token"; fi

# =============================================================================
section "3. Saga placement (LENIENT — 201 OR 422 both acceptable)"
# =============================================================================
PLACED_ORDER_ID=""
if [ -n "$CUST_TOK" ]; then
  IKEY="smoke-$(date +%s)-$RUN_SALT"
  req POST /api/v1/order/orders "$ITEMS_OK" "$CUST_TOK" "$TIMEOUT" "Idempotency-Key: $IKEY"
  SCODE="$RESP_CODE"
  if [ "$SCODE" = "201" ]; then
    PLACED_ORDER_ID=$(jf orderId)
    record PASS "saga" "POST /orders placed" "201" "201" "order_id=$PLACED_ORDER_ID"
    assert_nonempty "saga" "placed order has orderId" "$PLACED_ORDER_ID" "orderId"
    # idempotent replay: same Idempotency-Key → 200, SAME order_id
    req POST /api/v1/order/orders "$ITEMS_OK" "$CUST_TOK" "$TIMEOUT" "Idempotency-Key: $IKEY"
    assert_code "saga" "idempotent replay → 200" "200" "$RESP_CODE"
    assert_eq "saga" "replay returns same order_id" "$(jf orderId)" "$PLACED_ORDER_ID" "order_id"
  elif [ "$SCODE" = "422" ]; then
    # EXPECTED without seeded catalog stock + wallet balance — NOT a smoke failure.
    record PASS "saga" "POST /orders → 422 (expected w/o seeded preconditions)" "422" "201|422" "code=$(jf error.code)"
  elif [ "$SCODE" = "409" ]; then
    record WARN "saga" "POST /orders → 409 placement_in_progress" "409" "201|422" "saga still running (Temporal)"
  elif [ "$SCODE" = "502" ] || [ "$SCODE" = "503" ] || [ "$SCODE" = "500" ]; then
    record WARN "saga" "POST /orders saga infra down" "$SCODE" "201|422" "Temporal/peers unreachable — $(printf '%s' "$RESP_BODY" | head -c 120)"
  else
    record FAIL "saga" "POST /orders unexpected status" "$SCODE" "201|422" "$(printf '%s' "$RESP_BODY" | head -c 160)"
  fi
else record SKIP "saga" "POST /orders placement" "" "" "no customer token"; fi

# =============================================================================
section "4. Reads"
# =============================================================================
if [ -n "$CUST_TOK" ]; then
  req GET /api/v1/order/orders/me "" "$CUST_TOK"
  assert_code "reads" "GET /orders/me → 200" "200" "$RESP_CODE"
  [ "$RESP_CODE" = "200" ] && assert_nonempty "reads" "/orders/me has orders array" "$(jf orders)" "orders"
  if [ -n "$PLACED_ORDER_ID" ]; then
    req GET "/api/v1/order/orders/$PLACED_ORDER_ID" "" "$CUST_TOK"
    assert_code "reads" "GET /orders/{id} owner → 200" "200" "$RESP_CODE"
    [ "$RESP_CODE" = "200" ] && assert_eq "reads" "/orders/{id} id matches" "$(jf id)" "$PLACED_ORDER_ID" "id"
  fi
else record SKIP "reads" "GET /orders/me" "" "" "no customer token"; fi
# unauthenticated read → 401
req GET /api/v1/order/orders/me
assert_code "reads" "GET /orders/me no token → 401" "401" "$RESP_CODE"

# =============================================================================
section "5. gRPC east-west (Order.HasPurchased @ 20013) — non-gating"
# =============================================================================
if command -v grpcurl >/dev/null 2>&1; then
  ITOK=$(grep -E '^INTERNAL_SERVICE_TOKEN=' "$SCRIPT_DIR/../env/.env.dev" 2>/dev/null | head -1 | cut -d= -f2-)
  PA=(-import-path "$SCRIPT_DIR/../proto" -proto order.proto)
  QUERY_ID="${CUST_ID:-00000000-0000-0000-0000-000000000000}"
  PROD_ID="22222222-2222-2222-2222-222222222222"
  if [ -n "$ITOK" ]; then
    OUT=$(grpcurl -plaintext "${PA[@]}" -H "x-internal-token: $ITOK" \
      -d "{\"user_id\":\"$QUERY_ID\",\"product_id\":\"$PROD_ID\"}" "$GRPC_HOSTPORT" dokandar.order.v1.Order/HasPurchased 2>&1)
    grep -qiE 'purchased' <<<"$OUT" && record PASS "grpc" "HasPurchased returns answer" "" "" "ok" \
      || record WARN "grpc" "HasPurchased" "" "" "$(printf '%s' "$OUT" | head -c 120)"
    # missing token → UNAUTHENTICATED
    OUT2=$(grpcurl -plaintext "${PA[@]}" \
      -d "{\"user_id\":\"$QUERY_ID\",\"product_id\":\"$PROD_ID\"}" "$GRPC_HOSTPORT" dokandar.order.v1.Order/HasPurchased 2>&1)
    grep -qiE 'Unauthenticated|x-internal-token' <<<"$OUT2" && record PASS "grpc" "HasPurchased no token → UNAUTHENTICATED" "" "" "ok" \
      || record WARN "grpc" "HasPurchased no-token gate" "" "" "$(printf '%s' "$OUT2" | head -c 120)"
  else record INFO "grpc" "gRPC functional test" "" "" "skipped (no INTERNAL_SERVICE_TOKEN in env/.env.dev)"; fi
else
  (exec 3<>/dev/tcp/${GRPC_HOSTPORT/:/\/}) 2>/dev/null && record INFO "grpc" "gRPC port reachable (grpcurl absent)" "" "" "$GRPC_HOSTPORT open" \
    || record WARN "grpc" "gRPC port" "" "" "$GRPC_HOSTPORT closed"
fi

record INFO "done" "smoke complete" "" "" "see $RESULT_JSON"
