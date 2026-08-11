#!/usr/bin/env bash
# =============================================================================
# DOKANDAR API Gateway (15-api-gateway) — smoke / contract test harness
# -----------------------------------------------------------------------------
# The gateway is the STATELESS edge: it gates /ready on NOTHING (dependencies:[]),
# verifies RS256 JWTs against 01-auth's JWKS, rate-limits, and reverse-proxies
# /api/v1/<svc>/... verbatim. This harness asserts:
#   * the five ops endpoints + the gateway's identity + the bare-404,
#   * the EMPTY /ready dependencies[] (the load-bearing edge invariant),
#   * /health checks{} + the upstreams{} TCP-reachability map,
#   * the gateway-specific /metrics series,
#   * a PUBLIC proxied route works WITHOUT a token (catalog/search reads),
#   * a Bearer-required proxied route with NO token → 401 from the GATEWAY,
#   * JWKS verify works: a real RS256 token (minted via AUTH+SUPPORT OTP) on a
#     Bearer route is NOT 401 (it reaches/forwards past the gate).
#
# Design mirrors 01-auth/10-wallet: `set -uo pipefail` (a failed assertion is
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
load_env_file "$SCRIPT_DIR/../env/.env.dev"

# --- configuration (env-overridable) ----------------------------------------
GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:10015}"
AUTH_URL="${AUTH_URL:-http://127.0.0.1:10001}"
SUPPORT_URL="${SUPPORT_URL:-http://127.0.0.1:10099}"
AUTH_CONTAINER="${AUTH_CONTAINER:-dokandar_auth_service_dev}"
TIMEOUT="${TIMEOUT:-15}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-30}"
REQ_RETRIES="${REQ_RETRIES:-2}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/out}"
RESULT_JSON="${RESULT_JSON:-$OUTPUT_DIR/result.json}"
LOG="${LOG_FILE:-$OUTPUT_DIR/smoke.log}"
AUTH_SSH="${AUTH_SSH:-}"; AUTH_SSH_KEY="${AUTH_SSH_KEY:-}"
AUTH_SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
[ -n "$AUTH_SSH_KEY" ] && AUTH_SSH_OPTS="-i $AUTH_SSH_KEY $AUTH_SSH_OPTS"

# A PUBLIC proxied read route (catalog/search reads are public per architecture §5).
PUBLIC_PROXY_PATH="${PUBLIC_PROXY_PATH:-/api/v1/catalog/products}"
# A Bearer-required proxied route (wallet is per-user → gate fails closed).
BEARER_PROXY_PATH="${BEARER_PROXY_PATH:-/api/v1/wallet/me}"

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
# _http BASE METHOD PATH [BODY] [TOKEN] [TIMEOUT]
_http() {
  local base="$1" m="$2" p="$3" body="${4:-}" tok="${5:-}" to="${6:-$TIMEOUT}"
  local a=(-s -S -m "$to" -o "$BODYF" -w '%{http_code} %{size_download} %{content_type}' -X "$m" "$base$p")
  [ -n "$body" ] && a+=(-H 'Content-Type: application/json' --data "$body")
  [ -n "$tok" ]  && a+=(-H "Authorization: Bearer $tok")
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
req()  { _http "$GATEWAY_URL" "$@"; }   # service under test (the gateway)
areq() { _http "$AUTH_URL" "$@"; }      # auth (token minting)

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
# count keys of a JSON object at a dotted path
jcount() {
  printf '%s' "$RESP_BODY" | python3 -c '
import sys, json
try: d = json.loads(sys.stdin.read())
except Exception: print(0); sys.exit(0)
path = sys.argv[1]
if path:
    for p in path.split("."):
        d = d.get(p) if isinstance(d, dict) else None
        if d is None: break
print(len(d) if isinstance(d, (dict, list)) else 0)' "$1"
}
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

# --- token minting (via AUTH, NOT via the gateway proxy) ---------------------
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
  M_GATEWAY_URL="$GATEWAY_URL" M_AUTH_URL="$AUTH_URL" M_MODE="$MODE" M_REC="$OTP_RECOVERY" \
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
    ("service", "15-api-gateway"), ("gateway_url", os.environ.get("M_GATEWAY_URL", "")),
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

printf '%bDOKANDAR api-gateway smoke test%b  →  %s\n' "$BOLD" "$NC" "$GATEWAY_URL"
printf 'auth=%s  support=%s\nstarted %s\n' "$AUTH_URL" "$SUPPORT_URL" "$SMOKE_STARTED"

# --- preflight ---------------------------------------------------------------
if ! req GET /ready || [ "$RESP_CODE" = "000" ]; then
  record FAIL "preflight" "GET /ready reachable" "$RESP_CODE" "200" "cannot reach $GATEWAY_URL — on the box use http://127.0.0.1:10015"; exit 1
fi
CODE_VERSION=$(jf identity.code_version); TENANT=$(jf identity.tenant); ENVNAME=$(jf identity.env)
record INFO "preflight" "service identity" "" "" "code_version=$CODE_VERSION tenant=$TENANT env=$ENVNAME"
if ! areq GET /ready || [ "$RESP_CODE" = "000" ]; then
  record WARN "preflight" "AUTH /ready reachable" "$RESP_CODE" "200" "cannot reach $AUTH_URL — JWKS-mint section skipped"; AUTH_DOWN=1
else AUTH_DOWN=0; fi

# =============================================================================
section "1. Operational / contract surface"
# =============================================================================
req GET /ready
assert_code "ops" "GET /ready → 200 (gates on nothing)" "200" "$RESP_CODE"
assert_eq "ops" "/ready status==ready" "$(jf status)" "ready" "status"
assert_eq "ops" "/ready identity.service_name==15-api-gateway" "$(jf identity.service_name)" "15-api-gateway" "service_name"
assert_nonempty "ops" "/ready identity.code_version" "$(jf identity.code_version)" "code_version"
# THE load-bearing edge invariant: dependencies[] is EMPTY (§8.1/§16-a).
DEPS_N=$(jcount dependencies)
assert_eq "ops" "/ready dependencies[] is EMPTY (edge gates nothing)" "$DEPS_N" "0" "len"
assert_eq "ops" "  dependencies.0 absent" "$(jf dependencies.0)" "" "dep[0]"

req GET /health "" "" "" "$HEALTH_TIMEOUT"
assert_code "ops" "GET /health → 200 (diagnostic, never flips)" "200" "$RESP_CODE"
assert_eq "ops" "/health status==healthy" "$(jf status)" "healthy" "status"
for chk in redis jwks apm; do
  ok=$(jf "checks.$chk.ok")
  if [ -z "$ok" ]; then record FAIL "ops" "/health has check: $chk" "" "" "missing from checks{}"
  elif [ "$ok" = "True" ]; then record INFO "ops" "/health check $chk" "" "" "ok: $(jf checks.$chk.detail)"
  else record WARN "ops" "/health check $chk DOWN (non-gating)" "" "" "$(jf checks.$chk.detail)"; fi
done
UPN=$(jcount upstreams)
if [ "$UPN" -gt 0 ]; then record PASS "ops" "/health upstreams{} map present (TCP-probe)" "" "" "$UPN upstreams"
else record WARN "ops" "/health upstreams{} map" "" "" "empty — no UPSTREAM_<svc> configured?"; fi
assert_eq "ops" "/health observability.apm_service_name==15-api-gateway" "$(jf observability.apm_service_name)" "15-api-gateway" "apm_service_name"
assert_nonempty "ops" "/health observability.logs_sink_es" "$(jf observability.logs_sink_es)" "logs_sink_es"

req GET /data
if [ "$RESP_CODE" = "200" ]; then record PASS "ops" "/data → 200 (snapshot + identity)" "200" "200" "$(jf identity.service_name)"
elif [ "$RESP_CODE" = "404" ]; then assert_eq "ops" "/data 404 → no_snapshot" "$(jf error.code)" "no_snapshot" "code"
else record FAIL "ops" "/data 200|404" "$RESP_CODE" "200|404"; fi

req GET /metrics
{ [ "$RESP_CODE" != "200" ] || [ "${RESP_SIZE:-0}" = "0" ]; } && { sleep 0.5; req GET /metrics; }
assert_code "ops" "GET /metrics" "200" "$RESP_CODE"
case "$RESP_CT" in *text/plain*) record PASS "ops" "/metrics is text/plain (not JSON)" "" "" "$RESP_CT";; *) record WARN "ops" "/metrics content-type" "" "" "got '$RESP_CT'";; esac
# Prometheus client_golang emits NO line for a CounterVec until a label
# combination is observed once. http_requests_total has real traffic (preflight)
# and gateway_jwks_refresh_total is pre-seeded {result=ok|error} at boot, so both
# are present from the start → hard PASS/FAIL. gateway_rate_limited_total{route}
# and gateway_upstream_errors_total{upstream} carry RUNTIME labels: absent until a
# 429/502 actually happens — so their presence is asserted AFTER we exercise them
# (Section 5), not here. Here we only WARN if absent (legitimate on a quiet boot).
for metric in http_requests_total gateway_jwks_refresh_total; do
  if grep -q "$metric" <<<"$RESP_BODY"; then record PASS "ops" "/metrics exposes $metric (always present)" "" "" "present"
  else record FAIL "ops" "/metrics exposes $metric (always present)" "" "" "missing"; fi
done
for metric in gateway_rate_limited_total gateway_upstream_errors_total; do
  if grep -q "$metric" <<<"$RESP_BODY"; then record PASS "ops" "/metrics exposes $metric" "" "" "present (already exercised)"
  else record INFO "ops" "/metrics $metric not yet observed" "" "" "runtime-labeled — asserted after exercise (Section 5)"; fi
done
# gateway is stateless → there must be NO *_outbox_pending gauge (§10).
if grep -q 'outbox_pending' <<<"$RESP_BODY"; then record FAIL "ops" "/metrics has NO outbox gauge (stateless edge)" "" "" "found outbox_pending — gateway emits no events"
else record PASS "ops" "/metrics has NO outbox gauge (stateless edge)" "" "" "none, as required"; fi
grep -q 'service="15-api-gateway"' <<<"$RESP_BODY" && record PASS "ops" "/metrics service label == 15-api-gateway" "" "" "present" \
  || record WARN "ops" "/metrics service label" "" "" "service=\"15-api-gateway\" not yet observed"

req GET /docs
assert_code "ops" "GET /docs" "200" "$RESP_CODE"
case "$RESP_CT" in *text/html*) record PASS "ops" "/docs is text/html" "" "" "$RESP_CT";; *) record WARN "ops" "/docs content-type" "" "" "got '$RESP_CT'";; esac
req GET /openapi.json
assert_code "ops" "GET /openapi.json" "200" "$RESP_CODE"
assert_nonempty "ops" "/openapi.json has openapi version" "$(jf openapi)" "openapi"
assert_eq "ops" "/openapi.json title == DOKANDAR API Gateway" "$(jf info.title)" "DOKANDAR API Gateway" "title"
assert_eq "ops" "/openapi.json wires HTTPBearer scheme" "$(jf components.securitySchemes.HTTPBearer.scheme)" "bearer" "scheme"

# bare 404 — zero bytes, NO content-type, no body
req GET /this-path-does-not-exist
assert_code "ops" "unknown path → 404" "404" "$RESP_CODE"
assert_eq "ops" "  bare 404 body is zero-byte" "$RESP_SIZE" "0" "bytes"
case "$RESP_CT" in ""|" ") record PASS "ops" "  bare 404 has NO content-type" "" "" "empty CT";; *) record WARN "ops" "  bare 404 content-type" "" "" "got '$RESP_CT'";; esac

# =============================================================================
section "2. Reverse-proxy — verbatim forwarding"
# =============================================================================
# A PUBLIC proxied read forwards to the upstream WITHOUT a token. A reachable
# upstream returns its own status (200/400/404 from the SERVICE, not the bare
# gateway 404); an unreachable upstream returns the gateway's 502/504.
req GET "$PUBLIC_PROXY_PATH"
case "$RESP_CODE" in
  200|201|400|401|403|404|409|422)
    # 401/403 here would be the UPSTREAM's auth (it's a public-at-gateway route);
    # the key signal is "forwarded" — a NON-zero, NON-bare response.
    if [ "$RESP_CODE" = "404" ] && [ "${RESP_SIZE:-0}" = "0" ]; then
      record WARN "proxy" "public route forwards ($PUBLIC_PROXY_PATH)" "$RESP_CODE" "" "bare-404 — route not registered on the gateway?"
    else
      record PASS "proxy" "public route forwards WITHOUT token ($PUBLIC_PROXY_PATH)" "$RESP_CODE" "" "upstream answered"
    fi
    ;;
  502) record INFO "proxy" "public route → 502 upstream_error" "$RESP_CODE" "" "$(jf error.code) — 04-catalog down? (proxy path OK)" ;;
  504) record INFO "proxy" "public route → 504 upstream_timeout" "$RESP_CODE" "" "$(jf error.code) — 04-catalog slow? (proxy path OK)" ;;
  000) record WARN "proxy" "public route reachable" "$RESP_CODE" "" "no response from gateway" ;;
  *)   record WARN "proxy" "public route status" "$RESP_CODE" "" "unexpected (proxy path likely OK)" ;;
esac
# A public route must NOT be rejected by the gateway's own auth gate (no 401 from us).
if [ "$RESP_CODE" = "401" ]; then
  GW_CODE=$(jf error.code)
  case "$GW_CODE" in token_invalid|missing_token)
    record FAIL "proxy" "public route is NOT gateway-auth-gated" "401" "" "gateway rejected a public read (code=$GW_CODE)";;
  *) record INFO "proxy" "public route 401 is from upstream" "401" "" "code=$GW_CODE (not a gateway gate)";;
  esac
fi

# =============================================================================
section "3. Auth gate — Bearer route with NO token → 401 from the GATEWAY"
# =============================================================================
req GET "$BEARER_PROXY_PATH"
assert_code "authz" "Bearer route no token → 401 ($BEARER_PROXY_PATH)" "401" "$RESP_CODE"
GW_CODE=$(jf error.code)
case "$GW_CODE" in
  token_invalid|missing_token|unauthorized)
    record PASS "authz" "  401 is the gateway's error envelope" "" "" "code=$GW_CODE";;
  "") record WARN "authz" "  401 error envelope" "" "" "no error.code (is this the gateway or the upstream?)";;
  *)  record INFO "authz" "  401 error.code" "" "" "code=$GW_CODE";;
esac
# malformed bearer → still 401 (alg-confusion / garbage token rejected at the edge)
req GET "$BEARER_PROXY_PATH" "" "garbage.token.value"
assert_code "authz" "Bearer route malformed token → 401" "401" "$RESP_CODE"

# =============================================================================
section "4. JWKS verify — a real RS256 token passes the gateway gate"
# =============================================================================
TOKEN=""
if [ "${AUTH_DOWN:-0}" = "1" ]; then
  record SKIP "jwks" "RS256 token minting" "" "" "AUTH unreachable at $AUTH_URL"
else
  areq POST /api/v1/auth/signup/request "{\"phone\":\"$(gen_phone)\"}"
  probe=$(jf status)
  if [ "$probe" = "otp_disabled" ]; then MODE="off"; elif [ "$probe" = "otp_sent" ]; then MODE="on"; else MODE="unknown"; fi
  record INFO "jwks" "OTP mode (auth)" "" "" "MODE=$MODE (signup/request → '$probe')"
  if [ "$MODE" = "on" ]; then
    if support_reachable; then OTP_RECOVERY="support ($SUPPORT_URL)"
    elif command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$AUTH_CONTAINER"; then OTP_RECOVERY="docker-local"
    elif [ -n "$AUTH_SSH" ]; then OTP_RECOVERY="ssh"; else OTP_RECOVERY="none"; OTP_BLOCKED=1; fi
    [ "$OTP_BLOCKED" = "1" ] && record WARN "jwks" "OTP recovery available" "" "" "OTP ON but no recovery channel (set SUPPORT_URL / run on box / set AUTH_SSH)" \
      || record INFO "jwks" "OTP recovery channel" "" "" "$OTP_RECOVERY"
  fi
  otp_ready() { [ "$MODE" = "off" ] || { [ "$MODE" = "on" ] && [ "$OTP_BLOCKED" = "0" ]; }; }
  if otp_ready; then
    mint_customer "$(gen_phone)" "Gateway C1"
    if [ "$MC_CODE" = "201" ]; then
      TOKEN="$MC_ACCESS"
      record PASS "jwks" "customer minted (auth signup → 201)" "201" "201" "id=$MC_ID"
    else record WARN "jwks" "customer minting" "$MC_CODE" "201" "$(jf error.code) — JWKS-pass check skipped"; fi
  else record SKIP "jwks" "customer minting" "" "201" "OTP recovery blocked"; fi
fi

if [ -n "$TOKEN" ]; then
  # The crux: a VALID RS256 token must NOT be 401 at the gateway. If JWKS verify
  # were broken, the gateway would reject every fresh auth token with 401 (the
  # classic JWT_PUBLIC_KEY/JWKS drift bug). Any non-401 status (200/404/502/504
  # — upstream-dependent) proves the gate let it through.
  req GET "$BEARER_PROXY_PATH" "" "$TOKEN"
  if [ "$RESP_CODE" = "401" ]; then
    record FAIL "jwks" "gateway ACCEPTS a fresh auth RS256 token (JWKS verify)" "401" "not-401" \
      "gateway REJECTED a valid token → JWKS_URL unreachable or key drift vs 01-auth. The #1 edge bug."
  elif [ "$RESP_CODE" = "000" ]; then
    record WARN "jwks" "gateway accepts a fresh token" "$RESP_CODE" "not-401" "no response"
  else
    record PASS "jwks" "gateway ACCEPTS a fresh auth RS256 token (JWKS verify works)" "$RESP_CODE" "not-401" \
      "gate passed → forwarded to upstream (status from $BEARER_PROXY_PATH)"
  fi
else
  record SKIP "jwks" "gateway JWKS-pass check" "" "" "no token minted"
fi

# =============================================================================
section "5. Exercise the runtime-labeled edge metrics, then assert presence"
# =============================================================================
# gateway_rate_limited_total{route} + gateway_upstream_errors_total{upstream}
# carry runtime label values, so client_golang emits NO series for them until a
# 429 / 502 actually occurs. Drive each, then re-scrape /metrics and assert the
# names appear (this is what makes the "every gateway_* metric present" contract
# satisfiable without faking a series).

# --- (a) rate-limit: burst past RATE_LIMIT_MAX on a public route → expect a 429 -
RL_MAX="${RATE_LIMIT_MAX:-120}"
BURST=$(( RL_MAX + 40 ))
got429=0
for i in $(seq 1 "$BURST"); do
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$GATEWAY_URL$PUBLIC_PROXY_PATH" 2>/dev/null)
  [ "$code" = "429" ] && { got429=1; break; }
done
if [ "$got429" = "1" ]; then record PASS "metrics" "rate-limiter sheds a burst → 429 ($BURST reqs)" "429" "429" "token bucket fired"
else record WARN "metrics" "rate-limiter burst → 429" "" "429" "no 429 in $BURST reqs (limit high / fail-open / Redis down?)"; fi

# --- (b) upstream error: hit a route whose upstream is deliberately unreachable -
# A real upstream may be healthy, so we register a throwaway bad upstream by
# proxying a path whose service we point at a dead port via UPSTREAM override is
# not possible at runtime; instead hit a known-but-likely-unreachable optional
# upstream (risk/recommendation often not deployed in the smoke fleet) and accept
# 502/504 as the trigger. If everything is up, this stays a WARN (legitimate).
got5xx=0
for badpath in /api/v1/risk/score /api/v1/recommendation/feed /api/v1/reporting/ping; do
  code=$(curl -s -o /dev/null -m 6 -w '%{http_code}' "$GATEWAY_URL$badpath" 2>/dev/null)
  case "$code" in 502|504) got5xx=1; record INFO "metrics" "forced upstream error" "$code" "" "$badpath"; break;; esac
done
[ "$got5xx" = "1" ] && record PASS "metrics" "upstream failure surfaced → 502/504" "" "" "proxy error path exercised" \
  || record WARN "metrics" "upstream failure → 502/504" "" "" "all probed upstreams answered (no error to count)"

# --- re-scrape and assert the now-exercised counters are present ----------------
sleep 0.5
req GET /metrics
[ "$got429" = "1" ] && {
  if grep -q 'gateway_rate_limited_total' <<<"$RESP_BODY"; then record PASS "metrics" "/metrics exposes gateway_rate_limited_total (post-exercise)" "" "" "present"
  else record FAIL "metrics" "/metrics exposes gateway_rate_limited_total (post-exercise)" "" "" "still missing after a 429"; fi
}
[ "$got5xx" = "1" ] && {
  if grep -q 'gateway_upstream_errors_total' <<<"$RESP_BODY"; then record PASS "metrics" "/metrics exposes gateway_upstream_errors_total (post-exercise)" "" "" "present"
  else record FAIL "metrics" "/metrics exposes gateway_upstream_errors_total (post-exercise)" "" "" "still missing after a 502/504"; fi
}

# EXIT trap writes result.json + sets the exit code
