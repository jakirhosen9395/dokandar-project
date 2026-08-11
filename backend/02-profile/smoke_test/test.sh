#!/usr/bin/env bash
# =============================================================================
# DOKANDAR Profile Service — full smoke / contract test harness
# -----------------------------------------------------------------------------
# Exercises EVERY profile endpoint over HTTP and asserts the documented success
# codes AND the reachable failure codes (400/401/403/404/409/422/405).
#
# Profile is a DOWNSTREAM service: its protected routes require a real RS256
# access token, and a user's profile row only exists AFTER profile consumes
# auth's `dokandar.user.created` Kafka event. So this harness:
#   1. mints real users/tokens from the AUTH service (AUTH_URL) — reusing auth's
#      OTP flow, with codes recovered from the SUPPORT service (SUPPORT_URL),
#   2. POLLS profile /me until the user's profile materializes (the core
#      auth -> Kafka -> profile integration assertion),
#   3. exercises /me, /me/addresses, /me/avatar, public /geo/*, and
#      /admin/profiles/{user_id}, discovering valid BD geo codes from the
#      public geo API (no hardcoding).
#
# Cross-service endpoints come from the ENV (PROFILE_URL, AUTH_URL, SUPPORT_URL).
#
# Design mirrors 01-auth/smoke_test: `set -uo pipefail` (a failed assertion is
# data, not an abort); stdlib-only python3; result.json from an EXIT trap;
# infra-down reported as INFO/WARN, never FAIL.
#
# Usage: see smoke_test/test_command.md
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- robust .env loader: export ONLY valid KEY=VALUE pairs whose key is a legal
#     shell identifier (skips digit-prefixed fleet vars like 01_AUTH_HOST=…).
#     CLI-exported vars win (we only set what's unset). -------------------------
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
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    export "$key=$val"
  done < "$f"
}
load_env_file "$SCRIPT_DIR/.env"

# --- configuration (env-overridable) ---------------------------------------
PROFILE_URL="${PROFILE_URL:-http://127.0.0.1:10002}"   # the service under test
AUTH_URL="${AUTH_URL:-http://127.0.0.1:10001}"          # token minting (peer)
SUPPORT_URL="${SUPPORT_URL:-http://127.0.0.1:10099}"    # OTP-code recovery (peer)
ADMIN_PHONE="${ADMIN_PHONE:-01700000000}"
AUTH_CONTAINER="${AUTH_CONTAINER:-dokandar_auth_service_dev}"
TIMEOUT="${TIMEOUT:-15}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-30}"
REQ_RETRIES="${REQ_RETRIES:-2}"
MATERIALIZE_TIMEOUT="${MATERIALIZE_TIMEOUT:-40}"        # secs to wait for /me to appear
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/out}"
RESULT_JSON="${RESULT_JSON:-$OUTPUT_DIR/result.json}"
LOG="${LOG_FILE:-$OUTPUT_DIR/smoke.log}"
# OTP recovery over SSH (fallback for laptop runs without the support service):
AUTH_SSH="${AUTH_SSH:-}"
AUTH_SSH_KEY="${AUTH_SSH_KEY:-}"
REDIS_RESET_URL="${REDIS_RESET_URL:-}"

AUTH_SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
[ -n "$AUTH_SSH_KEY" ] && AUTH_SSH_OPTS="-i $AUTH_SSH_KEY $AUTH_SSH_OPTS"

mkdir -p "$OUTPUT_DIR"
TMPD="$(mktemp -d)"
BODYF="$TMPD/body"
RESULTS_TSV="$TMPD/results.tsv"
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
record() {  # status category name [http] [expected] [detail]
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
assert_code() {  # category name expected actual [detail]
  if [ "$4" = "$3" ]; then record PASS "$1" "$2" "$4" "$3" "${5:-}"
  else record FAIL "$1" "$2" "$4" "$3" "${5:-}"; fi
}
assert_eq() {    # category name actual expected [label]
  local lbl="${5:-value}"
  if [ "$3" = "$4" ]; then record PASS "$1" "$2" "" "" "$lbl='$3'"
  else record FAIL "$1" "$2" "" "" "$lbl='$3' want '$4'"; fi
}
assert_nonempty() {  # category name value [label]
  if [ -n "$3" ]; then record PASS "$1" "$2" "" "" "${4:-field} present"
  else record FAIL "$1" "$2" "" "" "${4:-field} missing/empty"; fi
}

# =============================================================================
# HTTP + JSON helpers
# =============================================================================
# _http BASE METHOD PATH [BODY] [TOKEN] [TIMEOUT] → RESP_CODE RESP_SIZE RESP_CT RESP_BODY
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
req()  { _http "$PROFILE_URL" "$@"; }   # the service under test
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
jwt_payload() {
  printf '%s' "$1" | python3 -c '
import sys, base64
t = sys.stdin.read().strip().split(".")
if len(t) < 2: print("{}"); sys.exit(0)
p = t[1] + "=" * (-len(t[1]) % 4)
try: sys.stdout.write(base64.urlsafe_b64decode(p).decode("utf-8"))
except Exception: print("{}")'
}
gen_uuid() { python3 -c 'import uuid;print(uuid.uuid4())'; }

RUN_SALT=$(( $(date +%s) % 1000000 ))
gen_phone() {  # ^01[3-9]\d{8}$  — counter in a FILE so it survives $(subshells)
  local n; n=$(( $(cat "$SEQ_FILE" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "$n" > "$SEQ_FILE"
  local ph; ph=$(printf '017%06d%02d' "$RUN_SALT" "$((n % 100))")
  printf '%s\n' "$ph" >> "$PHONES_FILE"
  printf '%s' "$ph"
}

# --- OTP recovery: support service (preferred) → docker logs → SSH ----------
read_otp_support() {  # phone purpose → latest code (or "")
  [ -n "$SUPPORT_URL" ] || return 0
  curl -s -m 8 "$SUPPORT_URL/otp/latest?phone=$1&purpose=$2" 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
print(d.get("code", "") if isinstance(d, dict) else "")' 2>/dev/null
}
read_otp_logs() {  # phone purpose → latest code (or "")
  local phone="$1" purpose="$2" code logs=""
  code=$(read_otp_support "$phone" "$purpose"); [ -n "$code" ] && { printf '%s' "$code"; return; }
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$AUTH_CONTAINER"; then
    logs=$(docker logs --tail 600 "$AUTH_CONTAINER" 2>&1)
  elif [ -n "$AUTH_SSH" ]; then
    logs=$(ssh $AUTH_SSH_OPTS "$AUTH_SSH" "docker logs --tail 600 $AUTH_CONTAINER 2>&1" 2>/dev/null)
  else
    return 0
  fi
  printf '%s\n' "$logs" | grep "DEV-OTP" | grep "phone=$phone" | grep "purpose=$purpose" \
    | tail -1 | grep -oE 'code=[0-9]+' | grep -oE '[0-9]+' | tail -1
}
support_reachable() {
  [ -n "$SUPPORT_URL" ] || return 1
  [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$SUPPORT_URL/health" 2>/dev/null)" = "200" ]
}
otp_code_for() {  # phone purpose [avoid_code] → code
  [ "$MODE" = "on" ] || { printf ''; return; }
  local i code="" avoid="${3:-}"
  for i in $(seq 1 12); do
    code=$(read_otp_logs "$1" "$2")
    [ -n "$code" ] && [ "$code" != "$avoid" ] && { printf '%s' "$code"; return; }
    sleep 0.5
  done
  printf '%s' "$code"
}
reset_otp_rate() {  # phone → clears the per-phone OTP rate counter (best-effort)
  local key="otp_rate:$1" url="$REDIS_RESET_URL"
  if [ -z "$url" ] && [ -f "$SCRIPT_DIR/../env/.env.dev" ]; then
    url=$(grep -E '^REDIS_URL=' "$SCRIPT_DIR/../env/.env.dev" 2>/dev/null | head -1 | cut -d= -f2-)
  fi
  if [ -n "$url" ]; then
    command -v redis-cli >/dev/null 2>&1 && redis-cli -u "$url" DEL "$key" >/dev/null 2>&1 && return 0
    command -v docker   >/dev/null 2>&1 && docker run --rm redis:7-alpine redis-cli -u "$url" DEL "$key" >/dev/null 2>&1 && return 0
  fi
  if [ -n "$AUTH_SSH" ]; then
    if ssh $AUTH_SSH_OPTS "$AUTH_SSH" bash -s "$AUTH_CONTAINER" "$key" >/dev/null 2>&1 <<'EOS'
docker exec "$1" python -c "import os,redis; redis.from_url(os.environ['REDIS_URL']).delete('$2')"
EOS
    then return 0; fi
  fi
  return 1
}

# --- token minting against AUTH (OTP-aware) ---------------------------------
# mint_customer phone name [email] → sets MC_CODE MC_ACCESS MC_REFRESH MC_ID
mint_customer() {
  local phone="$1" name="$2" email="${3:-}"
  local prev; prev=$(read_otp_logs "$phone" signup)
  areq POST /api/v1/auth/signup/request "{\"phone\":\"$phone\"}"
  local code body; code=$(otp_code_for "$phone" signup "$prev")
  body="{\"phone\":\"$phone\",\"name\":\"$name\",\"role\":\"customer\""
  [ -n "$email" ] && body="$body,\"email\":\"$email\""
  [ -n "$code" ] && body="$body,\"code\":\"$code\""
  body="$body}"
  areq POST /api/v1/auth/signup/verify "$body"
  MC_CODE="$RESP_CODE"; MC_ACCESS=""; MC_REFRESH=""; MC_ID=""
  if [ "$RESP_CODE" = "201" ]; then MC_ACCESS=$(jf access_token); MC_REFRESH=$(jf refresh_token); MC_ID=$(jf user.id); fi
}
# login_phone phone → sets LP_CODE LP_ACCESS LP_ID
login_phone() {
  local phone="$1"
  local prev; prev=$(read_otp_logs "$phone" login)
  areq POST /api/v1/auth/login/request "{\"phone\":\"$phone\"}"
  local code body; code=$(otp_code_for "$phone" login "$prev")
  body="{\"phone\":\"$phone\""; [ -n "$code" ] && body="$body,\"code\":\"$code\""; body="$body}"
  areq POST /api/v1/auth/login/verify "$body"
  LP_CODE="$RESP_CODE"; LP_ACCESS=""; LP_ID=""
  if [ "$RESP_CODE" = "200" ]; then LP_ACCESS=$(jf access_token); LP_ID=$(jf user.id); fi
}
# provision_login role name → admin-provisions a user via auth then OTP-logs in.
# Sets PV_OK PV_TOKEN PV_ID PV_PHONE PV_CREATE_CODE. Needs ADMIN_TOKEN.
provision_login() {
  local role="$1" name="$2"
  PV_OK=0; PV_TOKEN=""; PV_ID=""; PV_PHONE=""; PV_CREATE_CODE=""
  [ -n "$ADMIN_TOKEN" ] || return 0
  PV_PHONE=$(gen_phone)
  areq POST /api/v1/auth/users "{\"role\":\"$role\",\"phone\":\"$PV_PHONE\",\"name\":\"$name\"}" "$ADMIN_TOKEN"
  PV_CREATE_CODE="$RESP_CODE"
  [ "$RESP_CODE" = "201" ] || return 0
  PV_ID=$(jf user.id)
  login_phone "$PV_PHONE"
  [ "$LP_CODE" = "200" ] && { PV_TOKEN="$LP_ACCESS"; PV_OK=1; }
}

section() { printf '\n%b===== %s =====%b\n' "$BOLD" "$1" "$NC"; printf '\n===== %s =====\n' "$1" >> "$LOG"; }

# =============================================================================
# EXIT trap → always write result.json + summary
# =============================================================================
finish() {
  local finished phones; finished="$(date -u +%FT%TZ)"; phones=$(paste -sd, "$PHONES_FILE" 2>/dev/null || true)
  SMOKE_FINISHED="$finished" SMOKE_STARTED="$SMOKE_STARTED" \
  M_PROFILE_URL="$PROFILE_URL" M_AUTH_URL="$AUTH_URL" M_MODE="$MODE" M_REC="$OTP_RECOVERY" \
  M_CV="$CODE_VERSION" M_TENANT="$TENANT" M_ENV="$ENVNAME" M_PHONES="$phones" M_ADMIN="$ADMIN_PHONE" \
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
            rows.append({"status": st, "category": cat, "name": name,
                         "http_code": http, "expected": exp, "detail": det})
except FileNotFoundError:
    pass
c = Counter(r["status"] for r in rows)
summary = OrderedDict((k, c.get(k, 0)) for k in ("PASS", "FAIL", "SKIP", "WARN", "INFO"))
summary["total"] = len(rows)
cats = OrderedDict()
for r in rows:
    cats.setdefault(r["category"], Counter())[r["status"]] += 1
doc = OrderedDict()
doc["meta"] = OrderedDict([
    ("service", "profile"), ("profile_url", os.environ.get("M_PROFILE_URL", "")),
    ("auth_url", os.environ.get("M_AUTH_URL", "")),
    ("otp_mode", os.environ.get("M_MODE", "")), ("otp_recovery", os.environ.get("M_REC", "")),
    ("code_version", os.environ.get("M_CV", "")), ("tenant", os.environ.get("M_TENANT", "")),
    ("env", os.environ.get("M_ENV", "")), ("admin_phone", os.environ.get("M_ADMIN", "")),
    ("started_at", os.environ.get("SMOKE_STARTED", "")), ("finished_at", os.environ.get("SMOKE_FINISHED", "")),
    ("generated_test_phones", sorted({p for p in os.environ.get("M_PHONES", "").split(",") if p})),
])
doc["summary"] = summary
doc["by_category"] = {k: dict(v) for k, v in cats.items()}
doc["results"] = rows
with open(out, "w") as f:
    json.dump(doc, f, indent=2); f.write("\n")
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

printf '%bDOKANDAR profile smoke test%b  →  %s\n' "$BOLD" "$NC" "$PROFILE_URL"
printf 'auth=%s  support=%s\nstarted %s\n' "$AUTH_URL" "$SUPPORT_URL" "$SMOKE_STARTED"

# --- preflight -------------------------------------------------------------
if ! req GET /ready || [ "$RESP_CODE" = "000" ]; then
  record FAIL "preflight" "GET /ready reachable" "$RESP_CODE" "200" "cannot reach $PROFILE_URL — on the box use http://127.0.0.1:10002"
  exit 1
fi
CODE_VERSION=$(jf identity.code_version); TENANT=$(jf identity.tenant); ENVNAME=$(jf identity.env)
record INFO "preflight" "service identity" "" "" "code_version=$CODE_VERSION tenant=$TENANT env=$ENVNAME"
if ! areq GET /ready || [ "$RESP_CODE" = "000" ]; then
  record WARN "preflight" "AUTH /ready reachable" "$RESP_CODE" "200" "cannot reach $AUTH_URL — token minting (all authed sections) will be skipped"
  AUTH_DOWN=1
else AUTH_DOWN=0; fi

# =============================================================================
section "1. Operational / contract surface"
# =============================================================================
req GET /ready
RDY_STATUS=$(jf status)
if [ "$RESP_CODE" = "200" ]; then assert_eq "ops" "/ready status==ready when 200" "$RDY_STATUS" "ready" "status"
elif [ "$RESP_CODE" = "503" ]; then assert_eq "ops" "/ready status==not_ready when 503" "$RDY_STATUS" "not_ready" "status"
else record FAIL "ops" "/ready code is 200|503" "$RESP_CODE" "200|503"; fi
assert_nonempty "ops" "/ready identity.code_version" "$(jf identity.code_version)" "code_version"
assert_eq "ops" "/ready probes postgres" "$(jf dependencies.0.name)" "postgres" "dep[0]"
assert_eq "ops" "/ready probes redis" "$(jf dependencies.1.name)" "redis" "dep[1]"

req GET /health "" "" "$HEALTH_TIMEOUT"
HLT_STATUS=$(jf status)
if [ "$RESP_CODE" = "200" ]; then assert_eq "ops" "/health status==healthy when 200" "$HLT_STATUS" "healthy" "status"
elif [ "$RESP_CODE" = "503" ]; then assert_eq "ops" "/health status==unhealthy when 503" "$HLT_STATUS" "unhealthy" "status"
else record FAIL "ops" "/health code is 200|503" "$RESP_CODE" "200|503"; fi
# profile's gating checks: postgres, redis, kafka, mongo_logs, apm. grpc_media is
# diagnostic-only (non-gating) and is {ok:false,"not_configured"} until Media lands.
for dep in postgres redis kafka mongo_logs apm; do
  ok=$(jf "checks.$dep.ok"); detail=$(jf "checks.$dep.detail")
  if [ -z "$ok" ]; then record FAIL "ops" "/health has check: $dep" "" "" "missing from checks{}"
  elif [ "$ok" = "True" ]; then record INFO "ops" "/health dep $dep" "" "" "ok: $detail"
  else record WARN "ops" "/health dep $dep DOWN" "" "" "$detail (gating infra)"; fi
done
gm_ok=$(jf "checks.grpc_media.ok")
if [ -z "$gm_ok" ]; then record FAIL "ops" "/health has check: grpc_media" "" "" "missing"
else record INFO "ops" "/health grpc_media (diagnostic, non-gating)" "" "" "ok=$gm_ok detail=$(jf checks.grpc_media.detail)"; fi

req GET /data
if [ "$RESP_CODE" = "200" ]; then
  # Fleet convention (like auth/search): /data serves data/<tenant>/collect.sh snapshot
  record PASS "ops" "/data → 200 (collect.sh snapshot)" "200" "200" "kind=$(jf kind)"
  { [ "$(jf kind)" != "" ] && [ "$(jf host.hostname)" != "" ]; } \
    && record PASS "ops" "  snapshot has kind+host (not table counts)" "kind+host" "kind+host" "tenant snapshot"
elif [ "$RESP_CODE" = "404" ]; then
  # no result.json yet → honest "nothing to show" signal (run collect.sh)
  assert_eq "ops" "/data 404 → no_snapshot" "$(jf error.code)" "no_snapshot" "code"
else record FAIL "ops" "/data 200|404" "$RESP_CODE" "200|404"; fi

req GET /metrics
{ [ "$RESP_CODE" != "200" ] || [ "${RESP_SIZE:-0}" = "0" ]; } && { sleep 0.5; req GET /metrics; }
assert_code "ops" "GET /metrics" "200" "$RESP_CODE"
if grep -qE '^# (HELP|TYPE)|_total|go_|process_' <<<"$RESP_BODY"; then record PASS "ops" "/metrics looks like prometheus" "" "" "exposition format"
else record FAIL "ops" "/metrics looks like prometheus" "" "" "no metric lines (size=${RESP_SIZE:-?})"; fi

req GET /docs
assert_code "ops" "GET /docs" "200" "$RESP_CODE"
case "$RESP_CT" in *text/html*) record PASS "ops" "/docs is text/html" "" "" "$RESP_CT";; *) record WARN "ops" "/docs content-type" "" "" "got '$RESP_CT'";; esac

req GET /openapi.json
assert_code "ops" "GET /openapi.json" "200" "$RESP_CODE"
assert_nonempty "ops" "/openapi.json has openapi version" "$(jf openapi)" "openapi"
assert_eq "ops" "/openapi.json wires HTTPBearer scheme" "$(jf components.securitySchemes.HTTPBearer.scheme)" "bearer" "scheme"

# Info-hiding bare 404 — verified live: BOTH top-level and the mounted subrouter
# fall through to BareNotFound (zero bytes), since chi's Mount delegates unmatched
# subpaths to the parent NotFoundHandler.
req GET /this-path-does-not-exist
assert_code "ops" "unknown path → 404" "404" "$RESP_CODE"
assert_eq "ops" "unknown path body is zero-byte" "$RESP_SIZE" "0" "bytes"
req GET /api/v1/profile/not-a-real-route
assert_code "ops" "unknown profile subpath → 404" "404" "$RESP_CODE"
assert_eq "ops" "unknown profile subpath zero-byte" "$RESP_SIZE" "0" "bytes"
# 405 on a KNOWN path keeps the error envelope (debug info a real caller needs).
req POST /ready
assert_code "ops" "POST /ready → 405" "405" "$RESP_CODE"
assert_eq "ops" "  405 carries error.code" "$(jf error.code)" "method_not_allowed" "code"

# =============================================================================
section "2. Public geo reference (no token)"
# =============================================================================
req GET /api/v1/profile/geo/divisions
assert_code "geo" "GET /geo/divisions → 200" "200" "$RESP_CODE"
DIV1=$(jf items.0.code); DIV2=$(jf items.1.code)
assert_nonempty "geo" "  divisions non-empty" "$DIV1" "items[0].code"
DIST1=""; UPA1=""; UNION1=""; DIST_FOREIGN=""
if [ -n "$DIV1" ]; then
  req GET "/api/v1/profile/geo/divisions/$DIV1/districts"
  assert_code "geo" "GET /geo/divisions/$DIV1/districts → 200" "200" "$RESP_CODE"
  DIST1=$(jf items.0.code)
  assert_nonempty "geo" "  districts non-empty" "$DIST1" "items[0].code"
fi
if [ -n "$DIST1" ]; then
  req GET "/api/v1/profile/geo/districts/$DIST1/upazilas"
  assert_code "geo" "GET /geo/districts/$DIST1/upazilas → 200" "200" "$RESP_CODE"
  UPA1=$(jf items.0.code)
  assert_nonempty "geo" "  upazilas non-empty" "$UPA1" "items[0].code"
fi
if [ -n "$UPA1" ]; then
  req GET "/api/v1/profile/geo/upazilas/$UPA1/unions"
  assert_code "geo" "GET /geo/upazilas/$UPA1/unions → 200" "200" "$RESP_CODE"
  UNION1=$(jf items.0.code)   # may be empty (not all upazilas seed unions)
fi
# foreign district (belongs to DIV2) — used to force a geo_chain_invalid below
if [ -n "$DIV2" ]; then
  req GET "/api/v1/profile/geo/divisions/$DIV2/districts"
  DIST_FOREIGN=$(jf items.0.code)
fi
# unknown code → 404 WITH envelope (contrast to the bare 404 on unmapped paths)
req GET "/api/v1/profile/geo/divisions/ZZ-not-real/districts"
assert_code "geo" "unknown division → 404" "404" "$RESP_CODE"
assert_eq "geo" "  404 carries error.code" "$(jf error.code)" "not_found" "code"

# =============================================================================
section "3. Auth gate on protected routes"
# =============================================================================
req GET /api/v1/profile/me
assert_code "authz" "/me no token → 401" "401" "$RESP_CODE"
assert_eq "authz" "  code=token_missing" "$(jf error.code)" "token_missing" "code"
req GET /api/v1/profile/me "" "garbage.token.value"
assert_code "authz" "/me malformed token → 401" "401" "$RESP_CODE"
assert_eq "authz" "  code=token_invalid" "$(jf error.code)" "token_invalid" "code"

# =============================================================================
section "4. OTP mode + mint users from AUTH"
# =============================================================================
C1_ACCESS=""; C1_ID=""; C1_PHONE=""; C2_ACCESS=""; C2_ID=""; ADMIN_TOKEN=""; TOKENS_OK=0
SK1_TOKEN=""; SK1_ID=""; SK1_PHONE=""; SK2_TOKEN=""; SK2_ID=""; SS_TOKEN=""; SS_ID=""; PS_TOKEN=""; PS_ID=""
if [ "${AUTH_DOWN:-0}" = "1" ]; then
  record SKIP "mint" "all token minting" "" "" "AUTH unreachable at $AUTH_URL"
else
  areq POST /api/v1/auth/signup/request "{\"phone\":\"$(gen_phone)\"}"
  probe_status=$(jf status)
  if [ "$probe_status" = "otp_disabled" ]; then MODE="off"
  elif [ "$probe_status" = "otp_sent" ]; then MODE="on"
  else MODE="unknown"; fi
  record INFO "mint" "OTP mode (auth)" "" "" "MODE=$MODE (signup/request → '$probe_status')"
  if [ "$MODE" = "on" ]; then
    if support_reachable; then OTP_RECOVERY="support ($SUPPORT_URL)"
    elif command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$AUTH_CONTAINER"; then OTP_RECOVERY="docker-local"
    elif [ -n "$AUTH_SSH" ]; then OTP_RECOVERY="ssh"
    else OTP_RECOVERY="none"; OTP_BLOCKED=1; fi
    if [ "$OTP_BLOCKED" = "1" ]; then
      record FAIL "mint" "OTP recovery available" "" "" "OTP is ON but no recovery channel — set SUPPORT_URL to 00-support, run ON the box (docker), or set AUTH_SSH. Authed sections will be skipped."
    else
      record INFO "mint" "OTP recovery channel" "" "" "$OTP_RECOVERY"
      reset_otp_rate "$ADMIN_PHONE" && record INFO "mint" "admin OTP rate-limit reset" "" "" "cleared" \
        || record WARN "mint" "admin OTP rate-limit reset" "" "" "could not clear otp_rate:$ADMIN_PHONE (admin login may 429 on reruns)"
    fi
  fi
  otp_ready() { [ "$MODE" = "off" ] || { [ "$MODE" = "on" ] && [ "$OTP_BLOCKED" = "0" ]; }; }
  if otp_ready; then
    C1_PHONE=$(gen_phone)
    mint_customer "$C1_PHONE" "Profile C1"
    if [ "$MC_CODE" = "201" ]; then C1_ACCESS="$MC_ACCESS"; C1_ID="$MC_ID"
      record PASS "mint" "customer C1 minted (auth signup → 201)" "201" "201" "id=$C1_ID"
      # KEY-SANITY GATE: profile verifies the RS256 signature offline against its
      # configured JWT_PUBLIC_KEY_B64. If that key doesn't match auth's current
      # signing key, EVERY token is rejected (401 token_invalid) and no authed
      # route is testable. Detect that here and report the root cause clearly,
      # rather than letting it surface downstream as a confusing materialization
      # or admin failure. (A fresh token returning 404 profile_not_found = key OK,
      # row just not consumed yet → that's the materialization gate's job.)
      req GET /api/v1/profile/me "" "$C1_ACCESS"
      if [ "$RESP_CODE" = "401" ] && [ "$(jf error.code)" = "token_invalid" ]; then
        TOKENS_OK=0
        record FAIL "mint" "profile accepts auth-issued token" "401" "200|404" "profile REJECTED a freshly-minted auth token (RS256 verification error) → 02-profile env JWT_PUBLIC_KEY_B64 does NOT match auth's current signing key. Fix: copy auth's JWT_PUBLIC_KEY_B64 into 02-profile/env and restart profile (docker rm -f + run; env-file is a snapshot). All authed sections are skipped until then."
      else
        TOKENS_OK=1
        record PASS "mint" "profile accepts auth-issued token" "$RESP_CODE" "200|404" "RS256 verify OK (key aligned with auth)"
      fi
    else record FAIL "mint" "customer C1 minted" "$MC_CODE" "201" "$(jf error.code)"; fi
    mint_customer "$(gen_phone)" "Profile C2"
    [ "$MC_CODE" = "201" ] && { C2_ACCESS="$MC_ACCESS"; C2_ID="$MC_ID"; record PASS "mint" "customer C2 minted (isolation peer)" "201" "201" "id=$C2_ID"; } \
                           || record WARN "mint" "customer C2 minted" "$MC_CODE" "201" "isolation test will be skipped"
    login_phone "$ADMIN_PHONE"
    [ "$LP_CODE" = "200" ] && { ADMIN_TOKEN="$LP_ACCESS"; record PASS "mint" "admin login → 200" "200" "200" "for /admin/profiles"; } \
                           || record WARN "mint" "admin login" "$LP_CODE" "200" "admin + role sections will be skipped ($(jf error.code))"
    # provision + authenticate the remaining user types (admin-created, OTP login).
    # Proves profile mirrors EVERY role; SK1/SK2 also drive the KYC-mirror flow.
    if [ -n "$ADMIN_TOKEN" ]; then
      provision_login shopkeeper "Shopkeeper One";  SK1_TOKEN="$PV_TOKEN"; SK1_ID="$PV_ID"; SK1_PHONE="$PV_PHONE"
      [ "$PV_OK" = "1" ] && record PASS "mint" "shopkeeper provisioned + login → 200" "200" "200" "id=$SK1_ID" \
                         || record WARN "mint" "shopkeeper provision/login" "${PV_CREATE_CODE:-}" "201" "role-dependent + KYC checks limited"
      provision_login shopkeeper "Shopkeeper Two";  SK2_TOKEN="$PV_TOKEN"; SK2_ID="$PV_ID"
      [ "$PV_OK" = "1" ] && record PASS "mint" "2nd shopkeeper (KYC reject) → 200" "200" "200" "id=$SK2_ID" \
                         || record WARN "mint" "2nd shopkeeper provision/login" "${PV_CREATE_CODE:-}" "201" "KYC reject path limited"
      provision_login shop_staff "Shop Staff";      SS_TOKEN="$PV_TOKEN"; SS_ID="$PV_ID"
      [ "$PV_OK" = "1" ] && record PASS "mint" "shop_staff provisioned + login → 200" "200" "200" "id=$SS_ID" \
                         || record WARN "mint" "shop_staff provision/login" "${PV_CREATE_CODE:-}" "201" "RBAC 403 check limited"
      provision_login platform_staff "Platform Staff"; PS_TOKEN="$PV_TOKEN"; PS_ID="$PV_ID"
      [ "$PV_OK" = "1" ] && record PASS "mint" "platform_staff provisioned + login → 200" "200" "200" "id=$PS_ID" \
                         || record WARN "mint" "platform_staff provision/login" "${PV_CREATE_CODE:-}" "201" "RBAC 200 check limited"
    fi
  else
    record SKIP "mint" "user minting" "" "201" "OTP recovery blocked"
  fi
fi

# =============================================================================
section "5. Profile materialization (auth → Kafka → profile)"
# =============================================================================
C1_READY=0
if [ "$TOKENS_OK" = "1" ] && [ -n "$C1_ACCESS" ]; then
  deadline=$(( $(date +%s) + MATERIALIZE_TIMEOUT )); got=""; lastcode=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    req GET /api/v1/profile/me "" "$C1_ACCESS"
    lastcode="$RESP_CODE"
    if [ "$RESP_CODE" = "200" ]; then got=1; break; fi
    sleep 2
  done
  if [ -n "$got" ]; then
    C1_READY=1
    record PASS "materialize" "C1 profile appears via UserCreated event → 200" "200" "200" "consumed within ${MATERIALIZE_TIMEOUT}s"
  else
    # token is known-good (gate above), so a miss is either kafka-down (infra,
    # not profile's fault) or a real consumer/topic break. Capture the /me code
    # BEFORE probing /health (which overwrites RESP_BODY).
    req GET /health "" "" "$HEALTH_TIMEOUT"; kok=$(jf checks.kafka.ok)
    if [ "$kok" = "False" ]; then
      record WARN "materialize" "C1 profile did not appear (kafka DOWN)" "$lastcode" "200" "kafka non-reachable per /health — auth events buffer in the outbox; not profile's fault"
    else
      record FAIL "materialize" "C1 profile did not appear within ${MATERIALIZE_TIMEOUT}s" "$lastcode" "200" "kafka is UP, last /me HTTP $lastcode — check: did auth signup emit UserCreated? topic dokandar.user.created + consumer-group 'profile' aligned? auth outbox relay running?"
    fi
  fi
elif [ -n "$C1_ACCESS" ]; then
  record SKIP "materialize" "C1 profile materialization" "" "200" "profile rejects auth tokens (JWT key mismatch — see section 4 FAIL)"
else
  record SKIP "materialize" "C1 profile materialization" "" "200" "no C1 token"
fi

# =============================================================================
section "6. GET /me body"
# =============================================================================
if [ "$C1_READY" = "1" ]; then
  req GET /api/v1/profile/me "" "$C1_ACCESS"
  assert_code "me" "/me with C1 token → 200" "200" "$RESP_CODE"
  assert_eq "me" "  user_id==C1" "$(jf user_id)" "$C1_ID" "user_id"
  assert_eq "me" "  phone==C1 phone" "$(jf phone)" "$C1_PHONE" "phone"
  assert_eq "me" "  kyc defaults to unverified" "$(jf kyc)" "unverified" "kyc"
  assert_eq "me" "  locale defaults to bn" "$(jf locale)" "bn" "locale"
  # tampered-signature token must be rejected (proves signature is verified)
  req GET /api/v1/profile/me "" "${C1_ACCESS}x"
  assert_code "me" "/me tampered-signature token → 401" "401" "$RESP_CODE"
  assert_eq "me" "  code=token_invalid" "$(jf error.code)" "token_invalid" "code"
else record SKIP "me" "/me body assertions" "" "200" "C1 profile not materialized"; fi

# =============================================================================
section "7. PATCH/PUT /me (update + validation)"
# =============================================================================
if [ "$C1_READY" = "1" ]; then
  req PATCH /api/v1/profile/me "{\"name_en\":\"Updated En\",\"name_bn\":\"হালনাগাদ\",\"gender\":\"m\",\"locale\":\"en\",\"whatsapp_number\":\"01711112222\",\"dob\":\"1995-05-20\"}" "$C1_ACCESS"
  assert_code "patch" "PATCH /me valid → 200" "200" "$RESP_CODE"
  assert_eq "patch" "  name_en reflected" "$(jf name_en)" "Updated En" "name_en"
  assert_eq "patch" "  locale reflected" "$(jf locale)" "en" "locale"
  assert_eq "patch" "  gender reflected" "$(jf gender)" "m" "gender"
  assert_eq "patch" "  whatsapp_number reflected" "$(jf whatsapp_number)" "01711112222" "whatsapp"
  # the change persists on a fresh GET (cache invalidated on write)
  req GET /api/v1/profile/me "" "$C1_ACCESS"
  assert_eq "patch" "  persists on follow-up GET" "$(jf name_en)" "Updated En" "name_en"
  # PUT alias is also a partial update
  req PUT /api/v1/profile/me "{\"name_en\":\"Via Put\"}" "$C1_ACCESS"
  assert_code "patch" "PUT /me (alias) → 200" "200" "$RESP_CODE"
  assert_eq "patch" "  PUT updated name_en" "$(jf name_en)" "Via Put" "name_en"
  # validation negatives
  req PATCH /api/v1/profile/me "{\"locale\":\"fr\"}" "$C1_ACCESS"
  assert_code "patch" "bad locale → 422" "422" "$RESP_CODE"
  assert_eq "patch" "  code=invalid_request" "$(jf error.code)" "invalid_request" "code"
  req PATCH /api/v1/profile/me "{\"gender\":\"robot\"}" "$C1_ACCESS"
  assert_code "patch" "bad gender → 422" "422" "$RESP_CODE"
  req PATCH /api/v1/profile/me "{\"whatsapp_number\":\"12345\"}" "$C1_ACCESS"
  assert_code "patch" "bad whatsapp_number → 422" "422" "$RESP_CODE"
  assert_eq "patch" "  code=phone_invalid" "$(jf error.code)" "phone_invalid" "code"
  req PATCH /api/v1/profile/me "{\"dob\":\"20-05-1995\"}" "$C1_ACCESS"
  assert_code "patch" "bad dob format → 422" "422" "$RESP_CODE"
  req PATCH /api/v1/profile/me "not json" "$C1_ACCESS"
  assert_code "patch" "malformed JSON → 422" "422" "$RESP_CODE"
  assert_eq "patch" "  code=validation_error" "$(jf error.code)" "validation_error" "code"
else record SKIP "patch" "PATCH/PUT /me suite" "" "200" "C1 profile not materialized"; fi

# =============================================================================
section "8. POST /me/avatar"
# =============================================================================
if [ "$C1_READY" = "1" ]; then
  req POST /api/v1/profile/me/avatar "{}" "$C1_ACCESS"
  assert_code "avatar" "avatar missing media_id → 422" "422" "$RESP_CODE"
  assert_eq "avatar" "  code=validation_error" "$(jf error.code)" "validation_error" "code"
  AV_ID=$(gen_uuid)   # column is UUID; setAvatar persists it verbatim
  req POST /api/v1/profile/me/avatar "{\"media_id\":\"$AV_ID\"}" "$C1_ACCESS"
  assert_code "avatar" "avatar set (uuid media_id) → 200" "200" "$RESP_CODE"
  assert_eq "avatar" "  avatar_url is media:// stub" "$(jf avatar_url)" "media://$AV_ID" "avatar_url"
else record SKIP "avatar" "avatar suite" "" "200" "C1 profile not materialized"; fi

# =============================================================================
section "9. Addresses CRUD + validation + default invariant"
# =============================================================================
if [ "$C1_READY" = "1" ] && [ -n "$DIV1" ] && [ -n "$DIST1" ] && [ -n "$UPA1" ]; then
  req GET /api/v1/profile/me/addresses "" "$C1_ACCESS"
  assert_code "addr" "list addresses (empty) → 200" "200" "$RESP_CODE"

  # validation negatives (before any valid create)
  req POST /api/v1/profile/me/addresses "{\"label\":\"Home\"}" "$C1_ACCESS"
  assert_code "addr" "create missing fields → 422" "422" "$RESP_CODE"
  req POST /api/v1/profile/me/addresses "{\"label\":\"Home\",\"recipient_name\":\"X\",\"recipient_phone\":\"12345\",\"line1\":\"1 Rd\",\"division_code\":\"$DIV1\",\"district_code\":\"$DIST1\",\"upazila_code\":\"$UPA1\"}" "$C1_ACCESS"
  assert_code "addr" "create bad recipient_phone → 422" "422" "$RESP_CODE"
  assert_eq "addr" "  code=phone_invalid" "$(jf error.code)" "phone_invalid" "code"
  if [ -n "$DIST_FOREIGN" ] && [ "$DIST_FOREIGN" != "$DIST1" ]; then
    req POST /api/v1/profile/me/addresses "{\"label\":\"Home\",\"recipient_name\":\"X\",\"recipient_phone\":\"01711110000\",\"line1\":\"1 Rd\",\"division_code\":\"$DIV1\",\"district_code\":\"$DIST_FOREIGN\",\"upazila_code\":\"$UPA1\"}" "$C1_ACCESS"
    assert_code "addr" "create mismatched geo chain → 422" "422" "$RESP_CODE"
    assert_eq "addr" "  code=geo_chain_invalid" "$(jf error.code)" "geo_chain_invalid" "code"
  fi

  # A1 — default
  ub=""; [ -n "$UNION1" ] && ub=",\"union_code\":\"$UNION1\""
  req POST /api/v1/profile/me/addresses "{\"label\":\"Home\",\"recipient_name\":\"Recv One\",\"recipient_phone\":\"01712223333\",\"line1\":\"12 Test Road\",\"division_code\":\"$DIV1\",\"district_code\":\"$DIST1\",\"upazila_code\":\"$UPA1\"$ub,\"is_default\":true}" "$C1_ACCESS"
  assert_code "addr" "create A1 (default) → 201" "201" "$RESP_CODE"
  A1_ID=$(jf id)
  assert_nonempty "addr" "  A1 id" "$A1_ID" "id"
  assert_eq "addr" "  A1 is_default==true" "$(jf is_default)" "True" "is_default"
  assert_nonempty "addr" "  A1 hydrated division name" "$(jf division)" "division"

  # GET A1
  req GET "/api/v1/profile/me/addresses/$A1_ID" "" "$C1_ACCESS"
  assert_code "addr" "GET A1 → 200" "200" "$RESP_CODE"
  assert_eq "addr" "  recipient_phone round-trips" "$(jf recipient_phone)" "01712223333" "recipient_phone"
  # bad uuid → 400 invalid_uuid (clean, not a pgx 500 leak)
  req GET "/api/v1/profile/me/addresses/not-a-uuid" "" "$C1_ACCESS"
  assert_code "addr" "GET bad-uuid → 400" "400" "$RESP_CODE"
  assert_eq "addr" "  code=invalid_uuid" "$(jf error.code)" "invalid_uuid" "code"
  # well-formed but unknown uuid → 404 not_found
  req GET "/api/v1/profile/me/addresses/$(gen_uuid)" "" "$C1_ACCESS"
  assert_code "addr" "GET unknown uuid → 404" "404" "$RESP_CODE"
  assert_eq "addr" "  code=not_found" "$(jf error.code)" "not_found" "code"

  # PATCH A1
  req PATCH "/api/v1/profile/me/addresses/$A1_ID" "{\"label\":\"Office\"}" "$C1_ACCESS"
  assert_code "addr" "PATCH A1 label → 200" "200" "$RESP_CODE"
  assert_eq "addr" "  label updated" "$(jf label)" "Office" "label"
  # partial geo (only division) → 422 validation_error
  req PATCH "/api/v1/profile/me/addresses/$A1_ID" "{\"division_code\":\"$DIV1\"}" "$C1_ACCESS"
  assert_code "addr" "PATCH partial geo → 422" "422" "$RESP_CODE"

  # default invariant: can't delete the current default
  req DELETE "/api/v1/profile/me/addresses/$A1_ID" "" "$C1_ACCESS"
  assert_code "addr" "DELETE default A1 → 409" "409" "$RESP_CODE"
  assert_eq "addr" "  code=default_in_use" "$(jf error.code)" "default_in_use" "code"

  # A2 — promote, then A1 is deletable
  req POST /api/v1/profile/me/addresses "{\"label\":\"Second\",\"recipient_name\":\"Recv Two\",\"recipient_phone\":\"01713334444\",\"line1\":\"7 Second St\",\"division_code\":\"$DIV1\",\"district_code\":\"$DIST1\",\"upazila_code\":\"$UPA1\"$ub}" "$C1_ACCESS"
  assert_code "addr" "create A2 → 201" "201" "$RESP_CODE"
  A2_ID=$(jf id)
  req POST "/api/v1/profile/me/addresses/$A2_ID/default" "" "$C1_ACCESS"
  assert_code "addr" "set A2 default → 204" "204" "$RESP_CODE"
  # /me default_address now reflects A2
  req GET /api/v1/profile/me "" "$C1_ACCESS"
  assert_eq "addr" "  /me default_address.id==A2" "$(jf default_address.id)" "$A2_ID" "default.id"
  # now A1 (no longer default) deletes
  req DELETE "/api/v1/profile/me/addresses/$A1_ID" "" "$C1_ACCESS"
  assert_code "addr" "DELETE A1 (now non-default) → 204" "204" "$RESP_CODE"
  req DELETE "/api/v1/profile/me/addresses/$A1_ID" "" "$C1_ACCESS"
  assert_code "addr" "DELETE A1 again (gone) → 404" "404" "$RESP_CODE"
  # bad-uuid + setdefault unknown
  req POST "/api/v1/profile/me/addresses/not-a-uuid/default" "" "$C1_ACCESS"
  assert_code "addr" "set-default bad-uuid → 400" "400" "$RESP_CODE"
  req POST "/api/v1/profile/me/addresses/$(gen_uuid)/default" "" "$C1_ACCESS"
  assert_code "addr" "set-default unknown uuid → 404" "404" "$RESP_CODE"
elif [ "$C1_READY" = "1" ]; then
  record SKIP "addr" "address CRUD suite" "" "" "geo seed incomplete (DIV1=$DIV1 DIST1=$DIST1 UPA1=$UPA1)"
else
  record SKIP "addr" "address CRUD suite" "" "" "C1 profile not materialized"
fi

# =============================================================================
section "10. Cross-user isolation"
# =============================================================================
if [ "$C1_READY" = "1" ] && [ -n "$C2_ACCESS" ] && [ -n "$DIV1" ] && [ -n "$DIST1" ] && [ -n "$UPA1" ]; then
  ub=""; [ -n "$UNION1" ] && ub=",\"union_code\":\"$UNION1\""
  req POST /api/v1/profile/me/addresses "{\"label\":\"C2 Home\",\"recipient_name\":\"C2\",\"recipient_phone\":\"01714445555\",\"line1\":\"9 C2 Lane\",\"division_code\":\"$DIV1\",\"district_code\":\"$DIST1\",\"upazila_code\":\"$UPA1\"$ub}" "$C2_ACCESS"
  assert_code "isolation" "C2 creates an address → 201" "201" "$RESP_CODE"
  C2_ADDR=$(jf id)
  if [ -n "$C2_ADDR" ]; then
    # C1 must NOT be able to read C2's address (scoped by token sub) → 404
    req GET "/api/v1/profile/me/addresses/$C2_ADDR" "" "$C1_ACCESS"
    assert_code "isolation" "C1 reads C2's address → 404 (ownership scoped)" "404" "$RESP_CODE"
    assert_eq "isolation" "  code=not_found" "$(jf error.code)" "not_found" "code"
  fi
else record SKIP "isolation" "cross-user address isolation" "" "" "need C1+C2 tokens and geo seed"; fi

# =============================================================================
section "11. All user types — profile shell materializes for every role"
# =============================================================================
# Role isn't stored in the profile body (the migration has no role column), so
# the value here is proving the consumer creates a shell for EVERY role's
# UserCreated event — not re-checking a role-specific body.
mat_role() {  # token want_id label
  local tok="$1" want_id="$2" lbl="$3"
  [ -n "$tok" ] || { record SKIP "roles" "$lbl profile materializes" "" "200" "no $lbl token"; return; }
  local deadline=$(( $(date +%s) + MATERIALIZE_TIMEOUT )) c=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    req GET /api/v1/profile/me "" "$tok"; c="$RESP_CODE"
    [ "$c" = "200" ] && break; sleep 2
  done
  if [ "$c" = "200" ]; then
    record PASS "roles" "$lbl profile shell materializes → 200" "200" "200" "consumer handled $lbl UserCreated"
    [ -n "$want_id" ] && assert_eq "roles" "  $lbl /me user_id matches" "$(jf user_id)" "$want_id" "user_id"
  else
    req GET /health "" "" "$HEALTH_TIMEOUT"
    if [ "$(jf checks.kafka.ok)" = "False" ]; then
      record WARN "roles" "$lbl profile shell (kafka DOWN)" "$c" "200" "events buffered in outbox; not profile's fault"
    else
      record FAIL "roles" "$lbl profile shell did not materialize" "$c" "200" "kafka UP — consumer/topic issue for the $lbl UserCreated event"
    fi
  fi
}
if [ "$TOKENS_OK" = "1" ]; then
  mat_role "$SK1_TOKEN" "$SK1_ID" "shopkeeper"
  mat_role "$SS_TOKEN"  "$SS_ID"  "shop_staff"
  mat_role "$PS_TOKEN"  "$PS_ID"  "platform_staff"
  mat_role "$SK2_TOKEN" "$SK2_ID" "shopkeeper(2)"
  [ "$C1_READY" = "1" ] && record INFO "roles" "customer materialization" "" "" "covered in §5 (C1)"
else record SKIP "roles" "all-role materialization" "" "" "profile rejects tokens (JWT key mismatch — §4)"; fi

# =============================================================================
section "12. /admin/profiles RBAC across all roles"
# =============================================================================
# Allowed: admin, platform_staff.  Forbidden: shopkeeper, shop_staff, customer.
if [ "$TOKENS_OK" = "1" ] && [ "$C1_READY" = "1" ] && [ -n "$C1_ID" ]; then
  if [ -n "$ADMIN_TOKEN" ]; then
    req GET "/api/v1/profile/admin/profiles/$C1_ID" "" "$ADMIN_TOKEN"
    assert_code "rbac" "admin → 200" "200" "$RESP_CODE"
    assert_eq "rbac" "  user_id==C1" "$(jf user_id)" "$C1_ID" "user_id"
  fi
  [ -n "$PS_TOKEN" ] && { req GET "/api/v1/profile/admin/profiles/$C1_ID" "" "$PS_TOKEN"; assert_code "rbac" "platform_staff → 200" "200" "$RESP_CODE"; }
  if [ -n "$SK1_TOKEN" ]; then
    req GET "/api/v1/profile/admin/profiles/$C1_ID" "" "$SK1_TOKEN"
    assert_code "rbac" "shopkeeper → 403" "403" "$RESP_CODE"
    assert_eq "rbac" "  code=forbidden" "$(jf error.code)" "forbidden" "code"
  fi
  [ -n "$SS_TOKEN" ]  && { req GET "/api/v1/profile/admin/profiles/$C1_ID" "" "$SS_TOKEN";  assert_code "rbac" "shop_staff → 403" "403" "$RESP_CODE"; }
  [ -n "$C1_ACCESS" ] && { req GET "/api/v1/profile/admin/profiles/$C1_ID" "" "$C1_ACCESS"; assert_code "rbac" "customer → 403" "403" "$RESP_CODE"; }
  # admin negatives (uuid validation + not-found)
  if [ -n "$ADMIN_TOKEN" ]; then
    req GET "/api/v1/profile/admin/profiles/$(gen_uuid)" "" "$ADMIN_TOKEN"; assert_code "rbac" "admin unknown uuid → 404" "404" "$RESP_CODE"
    req GET "/api/v1/profile/admin/profiles/not-a-uuid" "" "$ADMIN_TOKEN"; assert_code "rbac" "admin bad uuid → 400" "400" "$RESP_CODE"
  fi
elif [ "$TOKENS_OK" = "1" ] && [ -n "$ADMIN_TOKEN" ]; then
  req GET "/api/v1/profile/admin/profiles/not-a-uuid" "" "$ADMIN_TOKEN"; assert_code "rbac" "admin bad uuid → 400" "400" "$RESP_CODE"
  record SKIP "rbac" "full RBAC matrix" "" "" "C1 not materialized"
else
  record SKIP "rbac" "/admin/profiles RBAC matrix" "" "" "no tokens (key mismatch?)"
fi

# =============================================================================
section "13. KYC state mirroring (auth → Kafka → profile.kyc)"
# =============================================================================
# The cross-service headline: a shopkeeper's KYC decisions in AUTH must flow to
# profile.kyc via Kafka (kyc.submitted→submitted, kyc.approved→verified,
# kyc.rejected→rejected). profile's MirrorKyc is an UPDATE (not an upsert), so
# the shell MUST exist first — guaranteed because §11 polled SK1/SK2 to 200 and
# we submit KYC only now.
poll_kyc() {  # token want label
  local tok="$1" want="$2" lbl="$3" deadline=$(( $(date +%s) + MATERIALIZE_TIMEOUT )) k=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    req GET /api/v1/profile/me "" "$tok"; k="$(jf kyc)"
    [ "$k" = "$want" ] && break; sleep 2
  done
  if [ "$k" = "$want" ]; then
    record PASS "kyc-mirror" "$lbl profile.kyc == $want" "" "$want" "mirrored via Kafka"
  else
    req GET /health "" "" "$HEALTH_TIMEOUT"
    if [ "$(jf checks.kafka.ok)" = "False" ]; then
      record WARN "kyc-mirror" "$lbl kyc → $want (kafka DOWN)" "" "$want" "events buffered in outbox; not profile's fault"
    else
      record FAIL "kyc-mirror" "$lbl profile.kyc did not reach '$want' (got '$k')" "" "$want" "kafka UP — either auth's kyc event lacks user_id, OR profile's MirrorKyc isn't consuming dokandar.kyc.*. Check both sides."
    fi
  fi
}
if [ "$TOKENS_OK" = "1" ] && [ -n "$SK1_TOKEN" ] && [ -n "$SK1_ID" ] && [ -n "$ADMIN_TOKEN" ]; then
  # SK1: submit (in auth) → mirror 'submitted' → admin approve → mirror 'verified'
  areq POST /api/v1/auth/kyc/submit "{\"nid_key\":\"kyc/$SK1_ID/nid.jpg\",\"trade_license_key\":\"kyc/$SK1_ID/tl.jpg\",\"bank_account_last4\":\"4321\",\"mobile_wallet_number\":\"01711111111\"}" "$SK1_TOKEN"
  assert_code "kyc-mirror" "SK1 auth kyc/submit → 202" "202" "$RESP_CODE"; SUB1=$(jf submission_id)
  poll_kyc "$SK1_TOKEN" "submitted" "SK1 after submit"
  if [ -n "$SUB1" ]; then
    areq POST "/api/v1/auth/kyc/$SUB1/approve" "" "$ADMIN_TOKEN"
    assert_code "kyc-mirror" "admin approve SK1 → 200" "200" "$RESP_CODE"
    poll_kyc "$SK1_TOKEN" "verified" "SK1 after approve"
  fi
  # SK2: submit → admin reject → mirror 'rejected'
  if [ -n "$SK2_TOKEN" ] && [ -n "$SK2_ID" ]; then
    areq POST /api/v1/auth/kyc/submit "{\"nid_key\":\"kyc/$SK2_ID/nid.jpg\"}" "$SK2_TOKEN"
    assert_code "kyc-mirror" "SK2 auth kyc/submit → 202" "202" "$RESP_CODE"; SUB2=$(jf submission_id)
    if [ -n "$SUB2" ]; then
      areq POST "/api/v1/auth/kyc/$SUB2/reject" "{\"reason\":\"Documents are illegible.\"}" "$ADMIN_TOKEN"
      assert_code "kyc-mirror" "admin reject SK2 → 200" "200" "$RESP_CODE"
      poll_kyc "$SK2_TOKEN" "rejected" "SK2 after reject"
    fi
  fi
else
  record SKIP "kyc-mirror" "KYC state mirroring" "" "" "need shopkeeper + admin tokens (and aligned JWT key)"
fi

# =============================================================================
section "14. Documented-but-not-exercised (transparency)"
# =============================================================================
record INFO "scope" "gRPC ProfileQuery (profile.proto, :20002)" "" "" "NOT-COVERED: HTTP harness; needs grpcurl + proto"
record INFO "scope" "503 dependency_unavailable" "" "" "NOT-EXERCISED: needs a live dep taken down"
record INFO "scope" "dokandar.user.updated mirror" "" "" "NOT-EXERCISED: profile consumes it, but auth has no emitting endpoint in this build"
record INFO "scope" "POST /me/avatar non-UUID media_id" "" "" "OBSERVATION: setAvatar lacks UUID format-check → pgx 500 (latent); not asserted (smoke tests assert documented behavior)"

# EXIT trap writes result.json + sets the exit code
