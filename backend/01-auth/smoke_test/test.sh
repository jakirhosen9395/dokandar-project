#!/usr/bin/env bash
# =============================================================================
# DOKANDAR Auth Service — full smoke / contract test harness
# -----------------------------------------------------------------------------
# Exercises EVERY auth endpoint over HTTP and asserts the documented success
# codes AND the reachable failure codes (400/401/403/404/409/422, plus 429 when
# OTP is on). Authenticates EVERY user type (customer, admin, shopkeeper,
# shop_staff, platform_staff). Produces a structured result.json + a log, and
# exits non-zero iff any assertion FAILED.
#
# MODE-ADAPTIVE on OTP_ENABLED:
#   * OTP off  → /verify accepts any code; full happy path runs over HTTP.
#   * OTP on   → the harness recovers the dev OTP from the auth container logs
#                ("[DEV-OTP] phone=.. purpose=.. code=.."). It reads them via
#                local `docker logs` (run ON the box) or over SSH (AUTH_SSH/
#                AUTH_SSH_KEY) when run from a laptop. It also RESETS the seeded
#                admin's per-phone OTP rate counter at startup so repeated runs
#                don't trip the 5/hour limit.
#
# Design: `set -uo pipefail` (NOT -e — a failed assertion is data, not abort);
# stdlib-only python3 (host, not the service venv); result.json from an EXIT
# trap (survives a crash); infra-down reported as INFO/WARN, never FAIL.
#
# Usage: see smoke_test/test_command.md
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- robust .env loader: export ONLY valid KEY=VALUE pairs whose key is a legal
#     shell identifier. This deliberately SKIPS the digit-prefixed fleet vars
#     (01_AUTH_HOST=…) that would otherwise make `source` print
#     "command not found". CLI-exported vars win (we only set what's unset). ----
load_env_file() {
  local f="$1" line key val
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|\#*) continue ;; esac
    [[ "$line" == [A-Za-z_]*=* ]] || continue
    key="${line%%=*}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [ -n "${!key:-}" ] && continue           # don't clobber an explicit export
    val="${line#*=}"
    # drop an inline comment ("value   # comment" — only when '#' follows
    # whitespace, mirroring how shell `source` treats VAR=val # comment), so a
    # commented value like `TIMEOUT=10  # seconds` doesn't poison curl flags.
    if [[ "$val" =~ ^(.*[^[:space:]])[[:space:]]+#.* ]]; then val="${BASH_REMATCH[1]}"; fi
    val="${val#"${val%%[![:space:]]*}"}"     # ltrim
    val="${val%"${val##*[![:space:]]}"}"     # rtrim
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    export "$key=$val"
  done < "$f"
}
load_env_file "$SCRIPT_DIR/.env"

# --- configuration (env-overridable) ---------------------------------------
AUTH_URL="${AUTH_URL:-http://127.0.0.1:10001}"
ADMIN_PHONE="${ADMIN_PHONE:-01700000000}"
AUTH_CONTAINER="${AUTH_CONTAINER:-dokandar_auth_service_dev}"
TIMEOUT="${TIMEOUT:-15}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-30}"
REQ_RETRIES="${REQ_RETRIES:-2}"             # retries on transient HTTP 000
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/out}"
RESULT_JSON="${RESULT_JSON:-$OUTPUT_DIR/result.json}"
LOG="${LOG_FILE:-$OUTPUT_DIR/smoke.log}"
# Preferred OTP-recovery channel: the `support` service (00-support) exposes
# captured OTPs over HTTP, so no docker/SSH access is needed. Works from a laptop
# too (just the support port). Falls back to docker-logs / SSH if unset/unreachable.
SUPPORT_URL="${SUPPORT_URL:-http://127.0.0.1:10099}"   # e.g. http://<box>:10099
# OTP recovery over SSH (fallback for laptop runs without support):
AUTH_SSH="${AUTH_SSH:-}"                     # e.g. ubuntu@13.233.126.113
AUTH_SSH_KEY="${AUTH_SSH_KEY:-}"             # e.g. /path/mumbai-key.pem
# admin OTP rate-limit reset (best-effort): a redis URL to the auth Redis.
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
# req METHOD PATH [BODY] [TOKEN] [TIMEOUT]  → RESP_CODE RESP_SIZE RESP_CT RESP_BODY
# retries on transient HTTP 000 (connection/timeout blips).
req() {
  local m="$1" p="$2" body="${3:-}" tok="${4:-}" to="${5:-$TIMEOUT}"
  local a=(-s -S -m "$to" -o "$BODYF" -w '%{http_code} %{size_download} %{content_type}' -X "$m" "$AUTH_URL$p")
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
read_otp_logs() {  # phone purpose → latest code (or "")  [name kept for callers]
  local phone="$1" purpose="$2" code logs=""
  # 1) the support service's API — no docker/ssh needed, works from anywhere
  code=$(read_otp_support "$phone" "$purpose"); [ -n "$code" ] && { printf '%s' "$code"; return; }
  # 2) local docker logs (on the box)
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$AUTH_CONTAINER"; then
    logs=$(docker logs --tail 600 "$AUTH_CONTAINER" 2>&1)
  elif [ -n "$AUTH_SSH" ]; then
    # 3) over SSH
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
  # Polls the logs for the LATEST code. When this phone+purpose already has an
  # earlier code in the logs (e.g. a re-request), pass that prior code as
  # `avoid` so we wait for the genuinely-new one instead of grabbing the stale
  # (already-burned) code and failing verification.
  [ "$MODE" = "on" ] || { printf ''; return; }
  local i code="" avoid="${3:-}"
  for i in $(seq 1 12); do
    code=$(read_otp_logs "$1" "$2")
    [ -n "$code" ] && [ "$code" != "$avoid" ] && { printf '%s' "$code"; return; }
    sleep 0.5
  done
  printf '%s' "$code"   # fall back to whatever we have
}
reset_otp_rate() {  # phone → clears the per-phone OTP rate counter (best-effort)
  local key="otp_rate:$1" url="$REDIS_RESET_URL"
  if [ -z "$url" ] && [ -f "$SCRIPT_DIR/../env/.env.dev" ]; then
    url=$(grep -E '^REDIS_URL=' "$SCRIPT_DIR/../env/.env.dev" 2>/dev/null | head -1 | cut -d= -f2-)
  fi
  # 1) directly — when Redis is reachable from here (on the box / same VPC)
  if [ -n "$url" ]; then
    command -v redis-cli >/dev/null 2>&1 && redis-cli -u "$url" DEL "$key" >/dev/null 2>&1 && return 0
    command -v docker   >/dev/null 2>&1 && docker run --rm redis:7-alpine redis-cli -u "$url" DEL "$key" >/dev/null 2>&1 && return 0
  fi
  # 2) over SSH (laptop runs) — delete via the auth container's OWN redis client,
  #    which can reach the VPC-private Redis even when this laptop cannot.
  if [ -n "$AUTH_SSH" ]; then
    if ssh $AUTH_SSH_OPTS "$AUTH_SSH" bash -s "$AUTH_CONTAINER" "$key" >/dev/null 2>&1 <<'EOS'
docker exec "$1" python -c "import os,redis; redis.from_url(os.environ['REDIS_URL']).delete('$2')"
EOS
    then return 0; fi
  fi
  return 1
}

# --- signup / login flows (OTP-aware, minimal OTP requests) -----------------
do_signup() {  # phone name [role] [email]  → DS_REQ_CODE DS_REQ_STATUS DS_VER_CODE
  local phone="$1" name="$2" role="${3:-customer}" email="${4:-}"
  local prev; prev=$(read_otp_logs "$phone" signup)   # code to avoid (prior request)
  req POST /api/v1/auth/signup/request "{\"phone\":\"$phone\"}"
  DS_REQ_CODE="$RESP_CODE"; DS_REQ_STATUS="$(jf status)"
  local code body; code=$(otp_code_for "$phone" signup "$prev")
  body="{\"phone\":\"$phone\",\"name\":\"$name\",\"role\":\"$role\""
  [ -n "$email" ] && body="$body,\"email\":\"$email\""
  [ -n "$code" ] && body="$body,\"code\":\"$code\""
  body="$body}"
  req POST /api/v1/auth/signup/verify "$body"
  DS_VER_CODE="$RESP_CODE"
}
do_login() {  # phone  → DL_REQ_CODE DL_VER_CODE DL_OK DL_ACCESS DL_REFRESH DL_ID
  local phone="$1"
  local prev; prev=$(read_otp_logs "$phone" login)   # code to avoid (prior request)
  req POST /api/v1/auth/login/request "{\"phone\":\"$phone\"}"
  DL_REQ_CODE="$RESP_CODE"
  local code body; code=$(otp_code_for "$phone" login "$prev")
  body="{\"phone\":\"$phone\""; [ -n "$code" ] && body="$body,\"code\":\"$code\""; body="$body}"
  req POST /api/v1/auth/login/verify "$body"
  DL_VER_CODE="$RESP_CODE"; DL_OK=0; DL_ACCESS=""; DL_REFRESH=""; DL_ID=""
  if [ "$RESP_CODE" = "200" ]; then DL_ACCESS=$(jf access_token); DL_REFRESH=$(jf refresh_token); DL_ID=$(jf user.id); DL_OK=1; fi
}

section() { printf '\n%b===== %s =====%b\n' "$BOLD" "$1" "$NC"; printf '\n===== %s =====\n' "$1" >> "$LOG"; }

# =============================================================================
# EXIT trap → always write result.json + summary
# =============================================================================
finish() {
  local finished phones; finished="$(date -u +%FT%TZ)"; phones=$(paste -sd, "$PHONES_FILE" 2>/dev/null || true)
  SMOKE_FINISHED="$finished" SMOKE_STARTED="$SMOKE_STARTED" \
  M_AUTH_URL="$AUTH_URL" M_MODE="$MODE" M_REC="$OTP_RECOVERY" M_CV="$CODE_VERSION" \
  M_TENANT="$TENANT" M_ENV="$ENVNAME" M_PHONES="$phones" M_ADMIN="$ADMIN_PHONE" \
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
    ("service", "auth"), ("auth_url", os.environ.get("M_AUTH_URL", "")),
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

printf '%bDOKANDAR auth smoke test%b  →  %s\n' "$BOLD" "$NC" "$AUTH_URL"
printf 'started %s\n' "$SMOKE_STARTED"

# --- preflight -------------------------------------------------------------
if ! req GET /ready || [ "$RESP_CODE" = "000" ]; then
  record FAIL "preflight" "GET /ready reachable" "$RESP_CODE" "200" "cannot reach $AUTH_URL — on the box use http://127.0.0.1:10001"
  exit 1
fi
CODE_VERSION=$(jf identity.code_version); TENANT=$(jf identity.tenant); ENVNAME=$(jf identity.env)
record INFO "preflight" "service identity" "" "" "code_version=$CODE_VERSION tenant=$TENANT env=$ENVNAME"

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

req GET /health "" "" "$HEALTH_TIMEOUT"
HLT_STATUS=$(jf status)
if [ "$RESP_CODE" = "200" ]; then assert_eq "ops" "/health status==healthy when 200" "$HLT_STATUS" "healthy" "status"
elif [ "$RESP_CODE" = "503" ]; then assert_eq "ops" "/health status==unhealthy when 503" "$HLT_STATUS" "unhealthy" "status"
else record FAIL "ops" "/health code is 200|503" "$RESP_CODE" "200|503"; fi
for dep in postgres redis kafka rabbitmq mongo_logs apm s3_kyc; do
  ok=$(jf "checks.$dep.ok"); detail=$(jf "checks.$dep.detail")
  if [ -z "$ok" ]; then record FAIL "ops" "/health has check: $dep" "" "" "missing from checks{}"
  elif [ "$ok" = "True" ]; then record INFO "ops" "/health dep $dep" "" "" "ok: $detail"
  else record WARN "ops" "/health dep $dep DOWN" "" "" "$detail (non-gating infra)"; fi
done

req GET /data
if [ "$RESP_CODE" = "200" ]; then record PASS "ops" "/data snapshot present" "200" "200" "valid snapshot"
elif [ "$RESP_CODE" = "404" ]; then assert_eq "ops" "/data 404 carries error.code" "$(jf error.code)" "no_snapshot" "code"
else record FAIL "ops" "/data 200|404" "$RESP_CODE" "200|404"; fi

req GET /metrics
{ [ "$RESP_CODE" != "200" ] || [ "${RESP_SIZE:-0}" = "0" ]; } && { sleep 0.5; req GET /metrics; }  # transient → one retry
assert_code "ops" "GET /metrics" "200" "$RESP_CODE"
if grep -qE '^# (HELP|TYPE)|_total|python_|process_' <<<"$RESP_BODY"; then record PASS "ops" "/metrics looks like prometheus" "" "" "exposition format"
else record FAIL "ops" "/metrics looks like prometheus" "" "" "no metric lines (size=${RESP_SIZE:-?})"; fi

req GET /docs
assert_code "ops" "GET /docs" "200" "$RESP_CODE"
case "$RESP_CT" in *text/html*) record PASS "ops" "/docs is text/html" "" "" "$RESP_CT";; *) record WARN "ops" "/docs content-type" "" "" "got '$RESP_CT'";; esac

req GET /openapi.json
assert_code "ops" "GET /openapi.json" "200" "$RESP_CODE"
assert_nonempty "ops" "/openapi.json has openapi version" "$(jf openapi)" "openapi"
assert_eq "ops" "/openapi.json wires bearerJwt scheme" "$(jf components.securitySchemes.bearerJwt.scheme)" "bearer" "scheme"

req GET /this-path-does-not-exist
assert_code "ops" "unknown path → 404" "404" "$RESP_CODE"
assert_eq "ops" "unknown path body is zero-byte" "$RESP_SIZE" "0" "bytes"
req GET /api/v1/auth/not-a-real-route
assert_code "ops" "unknown auth subpath → 404" "404" "$RESP_CODE"
assert_eq "ops" "unknown auth subpath zero-byte" "$RESP_SIZE" "0" "bytes"
req POST /ready
assert_code "ops" "POST /ready → 405" "405" "$RESP_CODE"

# =============================================================================
section "2. OTP mode detection + recovery readiness"
# =============================================================================
req POST /api/v1/auth/signup/request "{\"phone\":\"$(gen_phone)\"}"
probe_status=$(jf status)
if [ "$probe_status" = "otp_disabled" ]; then MODE="off"
elif [ "$probe_status" = "otp_sent" ]; then MODE="on"
else MODE="unknown"; fi
record INFO "mode" "OTP mode detected" "" "" "MODE=$MODE (signup/request → '$probe_status')"

if [ "$MODE" = "on" ]; then
  if support_reachable; then
    OTP_RECOVERY="support ($SUPPORT_URL)"
  elif command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$AUTH_CONTAINER"; then
    OTP_RECOVERY="docker-local"
  elif [ -n "$AUTH_SSH" ]; then
    OTP_RECOVERY="ssh"
  else
    OTP_RECOVERY="none"; OTP_BLOCKED=1
  fi
  if [ "$OTP_BLOCKED" = "1" ]; then
    record FAIL "mode" "OTP recovery available" "" "" "OTP is ON but no recovery channel — set SUPPORT_URL to the support service (00-support), run ON the box (docker), or set AUTH_SSH. OTP-gated flows will be skipped."
  else
    record INFO "mode" "OTP recovery channel" "" "" "$OTP_RECOVERY"
    # reset the seeded admin's per-phone OTP rate counter so reruns don't 429
    if reset_otp_rate "$ADMIN_PHONE"; then record INFO "mode" "admin OTP rate-limit reset" "" "" "otp_rate:$ADMIN_PHONE cleared"
    else record WARN "mode" "admin OTP rate-limit reset" "" "" "could not reach Redis to clear otp_rate:$ADMIN_PHONE (reruns may 429 admin login)"; fi
  fi
fi
otp_ready() { [ "$MODE" = "off" ] || { [ "$MODE" = "on" ] && [ "$OTP_BLOCKED" = "0" ]; }; }

# =============================================================================
section "3. Signup (self-service customer)"
# =============================================================================
req POST /api/v1/auth/signup/verify "{\"phone\":\"$(gen_phone)\",\"name\":\"Role Test\",\"role\":\"shopkeeper\"}"
assert_code "signup" "signup/verify role=shopkeeper → 403" "403" "$RESP_CODE"
assert_eq  "signup" "  code=role_not_self_serviceable" "$(jf error.code)" "role_not_self_serviceable" "code"
req POST /api/v1/auth/signup/request "{\"phone\":\"12345\"}"
assert_code "signup" "signup/request bad phone → 422" "422" "$RESP_CODE"
req POST /api/v1/auth/signup/verify "{\"phone\":\"12345\",\"name\":\"Bad\",\"role\":\"customer\"}"
assert_code "signup" "signup/verify bad phone → 422" "422" "$RESP_CODE"
req POST /api/v1/auth/signup/verify "{\"phone\":\"$(gen_phone)\",\"name\":\"x\",\"role\":\"customer\"}"
assert_code "signup" "signup/verify short name → 422" "422" "$RESP_CODE"
req POST /api/v1/auth/signup/request "{\"phone\":\"$ADMIN_PHONE\"}"
assert_code "signup" "signup/request existing phone → 409" "409" "$RESP_CODE"
assert_eq  "signup" "  code=phone_already_registered" "$(jf error.code)" "phone_already_registered" "code"

C1_PHONE=$(gen_phone); C1_ACCESS=""; C1_REFRESH=""; C1_ID=""
if otp_ready; then
  do_signup "$C1_PHONE" "Customer One" customer
  assert_code "signup" "signup/request → 202" "202" "$DS_REQ_CODE"
  if [ "$DS_VER_CODE" = "201" ]; then
    C1_ACCESS=$(jf access_token); C1_REFRESH=$(jf refresh_token); C1_ID=$(jf user.id)
    record PASS "signup" "signup/verify customer → 201" "201" "201" "user created"
    assert_nonempty "signup" "  access_token" "$C1_ACCESS" "access_token"
    assert_nonempty "signup" "  refresh_token" "$C1_REFRESH" "refresh_token"
    assert_eq "signup" "  user.role==customer" "$(jf user.role)" "customer" "role"
    assert_eq "signup" "  token_type==Bearer" "$(jf token_type)" "Bearer" "token_type"
    CLAIMS=$(jwt_payload "$C1_ACCESS")
    assert_eq "signup" "  JWT sub==user.id" "$(printf '%s' "$CLAIMS" | jget sub)" "$C1_ID" "sub"
    assert_eq "signup" "  JWT role==customer" "$(printf '%s' "$CLAIMS" | jget role)" "customer" "role"
    assert_eq "signup" "  JWT iss==dokandar-auth" "$(printf '%s' "$CLAIMS" | jget iss)" "dokandar-auth" "iss"
    assert_eq "signup" "  JWT phone==C1" "$(printf '%s' "$CLAIMS" | jget phone)" "$C1_PHONE" "phone"
    assert_nonempty "signup" "  JWT exp" "$(printf '%s' "$CLAIMS" | jget exp)" "exp"
  else
    record FAIL "signup" "signup/verify customer → 201" "$DS_VER_CODE" "201" "$(jf error.code)"
  fi
  # duplicate: signup/request for an already-registered phone → 409 at the
  # REQUEST step (the existing-user check precedes OTP generation, so this holds
  # in both OTP modes — verifying instead would fail OTP first under OTP-on).
  req POST /api/v1/auth/signup/request "{\"phone\":\"$C1_PHONE\"}"
  assert_code "signup" "signup/request duplicate phone → 409" "409" "$RESP_CODE"
  assert_eq  "signup" "  code=phone_already_registered" "$(jf error.code)" "phone_already_registered" "code"

  # DEEP: duplicate EMAIL → 409 (guards the IntegrityError→409 fix; pre-fix this
  # surfaced as a misleading 503 because email uniqueness wasn't pre-checked).
  DUP_EMAIL="dup_${RUN_SALT}@example.com"
  do_signup "$(gen_phone)" "Email One" customer "$DUP_EMAIL"
  if [ "$DS_VER_CODE" = "201" ]; then
    do_signup "$(gen_phone)" "Email Two" customer "$DUP_EMAIL"
    assert_code "signup" "signup/verify duplicate email → 409" "409" "$DS_VER_CODE"
    assert_eq  "signup" "  code=email_already_registered" "$(jf error.code)" "email_already_registered" "code"
  else
    record SKIP "signup" "duplicate email → 409" "$DS_VER_CODE" "409" "couldn't create the first email user"
  fi
else
  record SKIP "signup" "customer happy path" "" "201" "OTP recovery blocked (see section 2 root FAIL)"
fi

# =============================================================================
section "4. /me + access-token validation"
# =============================================================================
req GET /api/v1/auth/me
assert_code "me" "/me no token → 401" "401" "$RESP_CODE"
assert_eq  "me" "  code=token_missing" "$(jf error.code)" "token_missing" "code"
req GET /api/v1/auth/me "" "garbage.token.value"
assert_code "me" "/me bad token → 401" "401" "$RESP_CODE"
assert_eq  "me" "  code=token_invalid" "$(jf error.code)" "token_invalid" "code"
if [ -n "$C1_ACCESS" ]; then
  req GET /api/v1/auth/me "" "$C1_ACCESS"
  assert_code "me" "/me with C1 token → 200" "200" "$RESP_CODE"
  assert_eq "me" "  id==C1" "$(jf id)" "$C1_ID" "id"
  assert_eq "me" "  role==customer" "$(jf role)" "customer" "role"
  # DEEP: a structurally-valid JWT with a tampered signature must be rejected
  # (proves the signature is actually verified, not just decoded).
  req GET /api/v1/auth/me "" "${C1_ACCESS}x"
  assert_code "me" "/me tampered-signature token → 401" "401" "$RESP_CODE"
  assert_eq  "me" "  code=token_invalid" "$(jf error.code)" "token_invalid" "code"
else record SKIP "me" "/me with C1 token" "" "200" "no C1 token"; fi

# =============================================================================
section "5. Refresh rotation + reuse detection (family revoke)"
# =============================================================================
if [ -n "$C1_REFRESH" ]; then
  OLD_RT="$C1_REFRESH"
  req POST /api/v1/auth/refresh "{\"refresh_token\":\"$OLD_RT\"}"
  assert_code "refresh" "refresh rotate → 200" "200" "$RESP_CODE"
  NEW_RT=$(jf refresh_token)
  assert_nonempty "refresh" "  new refresh_token issued" "$NEW_RT" "refresh_token"
  if [ -n "$NEW_RT" ] && [ "$NEW_RT" != "$OLD_RT" ]; then record PASS "refresh" "  refresh_token rotated (differs)" "" "" "ok"
  else record FAIL "refresh" "  refresh_token rotated (differs)" "" "" "did not change"; fi
  req POST /api/v1/auth/refresh "{\"refresh_token\":\"$OLD_RT\"}"
  assert_code "refresh" "reuse old token → 401" "401" "$RESP_CODE"
  assert_eq  "refresh" "  code=refresh_reuse_detected" "$(jf error.code)" "refresh_reuse_detected" "code"
  if [ -n "$NEW_RT" ]; then
    req POST /api/v1/auth/refresh "{\"refresh_token\":\"$NEW_RT\"}"
    assert_code "refresh" "sibling token after family revoke → 401" "401" "$RESP_CODE"
  fi
else record SKIP "refresh" "rotation + reuse suite" "" "" "no C1 refresh token"; fi
req POST /api/v1/auth/refresh "{\"refresh_token\":\"\"}"
assert_code "refresh" "empty refresh_token → 422" "422" "$RESP_CODE"
req POST /api/v1/auth/refresh "{\"refresh_token\":\"nonexistent-token-value\"}"
assert_code "refresh" "unknown refresh_token → 401" "401" "$RESP_CODE"

# =============================================================================
section "6. Logout (idempotent revoke)"
# =============================================================================
if [ -n "$C1_ID" ] && otp_ready; then
  do_login "$C1_PHONE"
  if [ "$DL_OK" = "1" ] && [ -n "$DL_REFRESH" ]; then
    req POST /api/v1/auth/logout "{\"refresh_token\":\"$DL_REFRESH\"}"
    assert_code "logout" "logout → 204" "204" "$RESP_CODE"
    req POST /api/v1/auth/logout "{\"refresh_token\":\"$DL_REFRESH\"}"
    assert_code "logout" "logout again (idempotent) → 204" "204" "$RESP_CODE"
    # DEEP: a refresh token revoked by logout can't be used to rotate anymore
    req POST /api/v1/auth/refresh "{\"refresh_token\":\"$DL_REFRESH\"}"
    assert_code "logout" "refresh after logout (revoked) → 401" "401" "$RESP_CODE"
  else record SKIP "logout" "idempotent logout" "$DL_VER_CODE" "204" "could not login C1 for a disposable token"; fi
else record SKIP "logout" "idempotent logout" "" "204" "no C1 user / OTP blocked"; fi
req POST /api/v1/auth/logout "{\"refresh_token\":\"\"}"
assert_code "logout" "logout empty token → 422" "422" "$RESP_CODE"

# =============================================================================
section "7. Login flow"
# =============================================================================
req POST /api/v1/auth/login/request "{\"phone\":\"$(gen_phone)\"}"
assert_code "login" "login/request (unknown phone, anti-enum) → 202" "202" "$RESP_CODE"
req POST /api/v1/auth/login/verify "{\"phone\":\"not-a-phone\"}"
assert_code "login" "login/verify bad phone → 422" "422" "$RESP_CODE"
# unknown but well-formed phone: OTP-off → no code → 401; OTP-on → send a dummy
# code (no OTP is stored for an unknown phone) → 401 invalid_credentials.
UNKNOWN_PHONE=$(gen_phone)
if [ "$MODE" = "on" ]; then req POST /api/v1/auth/login/verify "{\"phone\":\"$UNKNOWN_PHONE\",\"code\":\"000000\"}"
else req POST /api/v1/auth/login/verify "{\"phone\":\"$UNKNOWN_PHONE\"}"; fi
assert_code "login" "login/verify unknown phone → 401" "401" "$RESP_CODE"
assert_eq  "login" "  code=invalid_credentials" "$(jf error.code)" "invalid_credentials" "code"

# =============================================================================
section "8. Admin bootstrap + RBAC + authenticate EVERY user type"
# =============================================================================
ADMIN_TOKEN=""
if otp_ready; then
  do_login "$ADMIN_PHONE"
  if [ "$DL_OK" = "1" ]; then
    ADMIN_TOKEN="$DL_ACCESS"
    record PASS "auth-roles" "admin login ($ADMIN_PHONE) → 200" "200" "200" "authenticated"
    req GET /api/v1/auth/me "" "$ADMIN_TOKEN"
    assert_eq "auth-roles" "  admin /me role==admin" "$(jf role)" "admin" "role"
  else
    record FAIL "auth-roles" "admin login ($ADMIN_PHONE) → 200" "$DL_VER_CODE" "200" "$(jf error.code) (rate-limited? admin not seeded?)"
  fi
else record SKIP "auth-roles" "admin login" "" "200" "OTP recovery blocked"; fi

# customer already authenticated in §3/§4
[ -n "$C1_ACCESS" ] && record PASS "auth-roles" "customer authenticated" "" "" "via self-signup (§3)" \
                     || record SKIP "auth-roles" "customer authenticated" "" "" "signup blocked"

# auth gate + negative RBAC
req POST /api/v1/auth/users "{\"role\":\"customer\",\"phone\":\"$(gen_phone)\",\"name\":\"NoAuth\"}"
assert_code "rbac" "POST /users no token → 401" "401" "$RESP_CODE"
if [ -n "$C1_ACCESS" ]; then
  req POST /api/v1/auth/users "{\"role\":\"shop_staff\",\"phone\":\"$(gen_phone)\",\"name\":\"ByCustomer\"}" "$C1_ACCESS"
  assert_code "rbac" "customer provisioning → 403" "403" "$RESP_CODE"
  assert_eq  "rbac" "  code=insufficient_role" "$(jf error.code)" "insufficient_role" "code"
fi

# provision + authenticate shopkeeper / shop_staff / platform_staff
SK1_PHONE=""; SK1_TOKEN=""; SK1_ID=""; PS_TOKEN=""
if [ -n "$ADMIN_TOKEN" ]; then
  # admin → shopkeeper (also reused by KYC as SK1)
  SK1_PHONE=$(gen_phone)
  req POST /api/v1/auth/users "{\"role\":\"shopkeeper\",\"phone\":\"$SK1_PHONE\",\"name\":\"Shopkeeper One\"}" "$ADMIN_TOKEN"
  assert_code "rbac" "admin → shopkeeper → 201" "201" "$RESP_CODE"
  assert_eq "rbac" "  user.role==shopkeeper" "$(jf user.role)" "shopkeeper" "role"; SK1_ID=$(jf user.id)
  req POST /api/v1/auth/users "{\"role\":\"shopkeeper\",\"phone\":\"$SK1_PHONE\",\"name\":\"Dup\"}" "$ADMIN_TOKEN"
  assert_code "rbac" "admin dup phone → 409" "409" "$RESP_CODE"
  req POST /api/v1/auth/users "{\"role\":\"wizard\",\"phone\":\"$(gen_phone)\",\"name\":\"Bad Role\"}" "$ADMIN_TOKEN"
  assert_code "rbac" "admin unknown role → 403" "403" "$RESP_CODE"
  req POST /api/v1/auth/users "{\"role\":\"customer\",\"phone\":\"nope\",\"name\":\"Bad Phone\"}" "$ADMIN_TOKEN"
  assert_code "rbac" "admin bad phone → 422" "422" "$RESP_CODE"

  # authenticate shopkeeper
  if otp_ready; then
    do_login "$SK1_PHONE"
    if [ "$DL_OK" = "1" ]; then SK1_TOKEN="$DL_ACCESS"
      record PASS "auth-roles" "shopkeeper login → 200" "200" "200" "authenticated"
      req GET /api/v1/auth/me "" "$SK1_TOKEN"; assert_eq "auth-roles" "  shopkeeper /me role" "$(jf role)" "shopkeeper" "role"
      # shopkeeper sub-matrix
      req POST /api/v1/auth/users "{\"role\":\"shop_staff\",\"phone\":\"$(gen_phone)\",\"name\":\"Staff By SK\"}" "$SK1_TOKEN"
      assert_code "rbac" "shopkeeper → shop_staff → 201" "201" "$RESP_CODE"
      req POST /api/v1/auth/users "{\"role\":\"admin\",\"phone\":\"$(gen_phone)\",\"name\":\"Esc\"}" "$SK1_TOKEN"
      assert_code "rbac" "shopkeeper → admin (privilege escalation) → 403" "403" "$RESP_CODE"
    else record FAIL "auth-roles" "shopkeeper login → 200" "$DL_VER_CODE" "200" "could not authenticate"; fi
  fi

  # admin → shop_staff, then authenticate
  SS_PHONE=$(gen_phone)
  req POST /api/v1/auth/users "{\"role\":\"shop_staff\",\"phone\":\"$SS_PHONE\",\"name\":\"Shop Staff\"}" "$ADMIN_TOKEN"
  assert_code "rbac" "admin → shop_staff → 201" "201" "$RESP_CODE"
  if otp_ready; then
    do_login "$SS_PHONE"
    if [ "$DL_OK" = "1" ]; then record PASS "auth-roles" "shop_staff login → 200" "200" "200" "authenticated"
      req GET /api/v1/auth/me "" "$DL_ACCESS"; assert_eq "auth-roles" "  shop_staff /me role" "$(jf role)" "shop_staff" "role"
      # shop_staff may provision customers only
      req POST /api/v1/auth/users "{\"role\":\"customer\",\"phone\":\"$(gen_phone)\",\"name\":\"Walkin\"}" "$DL_ACCESS"
      assert_code "rbac" "shop_staff → customer → 201" "201" "$RESP_CODE"
      # DEEP: shop_staff may NOT create another shop_staff
      req POST /api/v1/auth/users "{\"role\":\"shop_staff\",\"phone\":\"$(gen_phone)\",\"name\":\"Nope\"}" "$DL_ACCESS"
      assert_code "rbac" "shop_staff → shop_staff (forbidden) → 403" "403" "$RESP_CODE"
    else record FAIL "auth-roles" "shop_staff login → 200" "$DL_VER_CODE" "200" "could not authenticate"; fi
  fi

  # admin → platform_staff, then authenticate (KYC reviewer role)
  PS_PHONE=$(gen_phone)
  req POST /api/v1/auth/users "{\"role\":\"platform_staff\",\"phone\":\"$PS_PHONE\",\"name\":\"Platform Staff\"}" "$ADMIN_TOKEN"
  assert_code "rbac" "admin → platform_staff → 201" "201" "$RESP_CODE"
  if otp_ready; then
    do_login "$PS_PHONE"
    if [ "$DL_OK" = "1" ]; then PS_TOKEN="$DL_ACCESS"; record PASS "auth-roles" "platform_staff login → 200" "200" "200" "authenticated"
      req GET /api/v1/auth/me "" "$PS_TOKEN"; assert_eq "auth-roles" "  platform_staff /me role" "$(jf role)" "platform_staff" "role"
      # DEEP: platform_staff is a reviewer, not a provisioner → cannot create users
      req POST /api/v1/auth/users "{\"role\":\"customer\",\"phone\":\"$(gen_phone)\",\"name\":\"Nope\"}" "$PS_TOKEN"
      assert_code "rbac" "platform_staff → customer (not a provisioner) → 403" "403" "$RESP_CODE"
    else record FAIL "auth-roles" "platform_staff login → 200" "$DL_VER_CODE" "200" "could not authenticate"; fi
  fi
else
  record SKIP "rbac" "admin-gated provisioning matrix" "" "" "no admin token"
  record SKIP "auth-roles" "shopkeeper/shop_staff/platform_staff" "" "" "no admin token"
fi

# =============================================================================
section "9. KYC lifecycle (submit → queue → approve / reject)"
# =============================================================================
if [ -n "$SK1_TOKEN" ] && [ -n "$ADMIN_TOKEN" ]; then
  [ -n "$C1_ACCESS" ] && {
    req POST /api/v1/auth/kyc/submit "{\"nid_key\":\"kyc/$C1_ID/nid.jpg\"}" "$C1_ACCESS"
    assert_code "kyc" "customer kyc/submit → 403" "403" "$RESP_CODE"
    assert_eq  "kyc" "  code=insufficient_role" "$(jf error.code)" "insufficient_role" "code"; }
  req POST /api/v1/auth/kyc/submit "{\"nid_key\":\"kyc/00000000-0000-0000-0000-000000000000/nid.jpg\"}" "$SK1_TOKEN"
  assert_code "kyc" "kyc/submit nid wrong-prefix → 422" "422" "$RESP_CODE"
  # DEEP: valid nid but trade_license under someone else's prefix → 422
  req POST /api/v1/auth/kyc/submit "{\"nid_key\":\"kyc/$SK1_ID/nid.jpg\",\"trade_license_key\":\"kyc/00000000-0000-0000-0000-000000000000/tl.jpg\"}" "$SK1_TOKEN"
  assert_code "kyc" "kyc/submit trade_license wrong-prefix → 422" "422" "$RESP_CODE"
  req POST /api/v1/auth/kyc/submit "{\"nid_key\":\"kyc/$SK1_ID/nid.jpg\",\"trade_license_key\":\"kyc/$SK1_ID/tl.jpg\",\"bank_account_last4\":\"4321\",\"mobile_wallet_number\":\"01711111111\"}" "$SK1_TOKEN"
  assert_code "kyc" "SK1 kyc/submit → 202" "202" "$RESP_CODE"; SUB1_ID=$(jf submission_id)
  assert_nonempty "kyc" "  submission_id" "$SUB1_ID" "submission_id"
  req POST /api/v1/auth/kyc/submit "{\"nid_key\":\"kyc/$SK1_ID/nid2.jpg\"}" "$SK1_TOKEN"
  assert_code "kyc" "SK1 second submit (pending) → 409" "409" "$RESP_CODE"
  assert_eq  "kyc" "  code=kyc_already_submitted" "$(jf error.code)" "kyc_already_submitted" "code"
  req GET /api/v1/auth/kyc/me "" "$SK1_TOKEN"
  assert_code "kyc" "SK1 kyc/me → 200" "200" "$RESP_CODE"
  assert_eq "kyc" "  kyc==submitted" "$(jf kyc)" "submitted" "kyc"
  [ -n "$C1_ACCESS" ] && { req GET /api/v1/auth/kyc/queue "" "$C1_ACCESS"; assert_code "kyc" "customer kyc/queue → 403" "403" "$RESP_CODE"; }
  req GET /api/v1/auth/kyc/queue "" "$ADMIN_TOKEN"
  assert_code "kyc" "admin kyc/queue → 200" "200" "$RESP_CODE"
  grep -q "$SUB1_ID" <<<"$RESP_BODY" && record PASS "kyc" "  queue contains SK1 submission" "" "" "found" \
                                                || record WARN "kyc" "  queue contains SK1 submission" "" "" "not found"
  # platform_staff can also view the queue (alt reviewer role)
  [ -n "$PS_TOKEN" ] && { req GET /api/v1/auth/kyc/queue "" "$PS_TOKEN"; assert_code "kyc" "platform_staff kyc/queue → 200" "200" "$RESP_CODE"; }
  # decision negatives
  [ -n "$C1_ACCESS" ] && { req POST "/api/v1/auth/kyc/$SUB1_ID/approve" "" "$C1_ACCESS"; assert_code "kyc" "customer approve → 403" "403" "$RESP_CODE"; }
  req POST "/api/v1/auth/kyc/not-a-uuid/approve" "" "$ADMIN_TOKEN"
  assert_code "kyc" "approve bad-uuid → 422" "422" "$RESP_CODE"
  req POST "/api/v1/auth/kyc/00000000-0000-0000-0000-000000000000/approve" "" "$ADMIN_TOKEN"
  assert_code "kyc" "approve nonexistent → 404" "404" "$RESP_CODE"
  req POST "/api/v1/auth/kyc/$SUB1_ID/approve" "" "$ADMIN_TOKEN"
  assert_code "kyc" "admin approve SK1 → 200" "200" "$RESP_CODE"
  assert_eq "kyc" "  decision==verified" "$(jf decision)" "verified" "decision"
  req POST "/api/v1/auth/kyc/$SUB1_ID/approve" "" "$ADMIN_TOKEN"
  assert_code "kyc" "re-approve SK1 → 409" "409" "$RESP_CODE"
  assert_eq  "kyc" "  code=already_reviewed" "$(jf error.code)" "already_reviewed" "code"
  req GET /api/v1/auth/kyc/me "" "$SK1_TOKEN"
  assert_eq "kyc" "SK1 kyc/me after approve == verified" "$(jf kyc)" "verified" "kyc"

  # second shopkeeper → reject path (incl. 422 short reason)
  SK2_PHONE=$(gen_phone)
  req POST /api/v1/auth/users "{\"role\":\"shopkeeper\",\"phone\":\"$SK2_PHONE\",\"name\":\"Shopkeeper Two\"}" "$ADMIN_TOKEN"
  SK2_ID=$(jf user.id)
  if otp_ready; then
    do_login "$SK2_PHONE"
    if [ "$DL_OK" = "1" ] && [ -n "$SK2_ID" ]; then SK2_TOKEN="$DL_ACCESS"
      req POST /api/v1/auth/kyc/submit "{\"nid_key\":\"kyc/$SK2_ID/nid.jpg\"}" "$SK2_TOKEN"
      assert_code "kyc" "SK2 kyc/submit → 202" "202" "$RESP_CODE"; SUB2_ID=$(jf submission_id)
      req POST "/api/v1/auth/kyc/$SUB2_ID/reject" "{\"reason\":\"x\"}" "$ADMIN_TOKEN"
      assert_code "kyc" "reject short reason → 422" "422" "$RESP_CODE"
      req POST "/api/v1/auth/kyc/$SUB2_ID/reject" "{\"reason\":\"Documents are illegible.\"}" "$ADMIN_TOKEN"
      assert_code "kyc" "admin reject SK2 → 200" "200" "$RESP_CODE"
      assert_eq "kyc" "  decision==rejected" "$(jf decision)" "rejected" "decision"
      req GET /api/v1/auth/kyc/me "" "$SK2_TOKEN"
      assert_eq "kyc" "SK2 kyc/me after reject == rejected" "$(jf kyc)" "rejected" "kyc"
    else record SKIP "kyc" "reject path (SK2)" "$DL_VER_CODE" "" "could not login SK2"; fi
  fi
else record SKIP "kyc" "full KYC lifecycle" "" "" "need shopkeeper + admin tokens"; fi

# =============================================================================
section "10. JWKS + JWT verification"
# =============================================================================
req GET /api/v1/auth/jwks
assert_code "jwt" "GET /jwks → 200" "200" "$RESP_CODE"
assert_eq "jwt" "  keys[0].kty==RSA" "$(jf keys.0.kty)" "RSA" "kty"
assert_eq "jwt" "  keys[0].alg==RS256" "$(jf keys.0.alg)" "RS256" "alg"
assert_eq "jwt" "  keys[0].use==sig" "$(jf keys.0.use)" "sig" "use"
assert_nonempty "jwt" "  keys[0].kid" "$(jf keys.0.kid)" "kid"
assert_nonempty "jwt" "  keys[0].n (modulus)" "$(jf keys.0.n)" "n"
if [ -n "$C1_ACCESS" ] && python3 -c 'import jwt, cryptography' >/dev/null 2>&1; then
  JWKS_BODY=$(curl -s -m "$TIMEOUT" "$AUTH_URL/api/v1/auth/jwks")
  if AT="$C1_ACCESS" JWKS="$JWKS_BODY" python3 - <<'PYV' ; then
import os, json, jwt
from jwt.algorithms import RSAAlgorithm
jwks = json.loads(os.environ["JWKS"]); key = RSAAlgorithm.from_jwk(json.dumps(jwks["keys"][0]))
claims = jwt.decode(os.environ["AT"], key, algorithms=["RS256"], issuer="dokandar-auth",
                    options={"require": ["exp", "iat", "sub"]})
raise SystemExit(0 if claims.get("role") == "customer" else 2)
PYV
    record PASS "jwt" "access token verifies against /jwks (RS256)" "" "" "signature + issuer + claims OK"
  else record FAIL "jwt" "access token verifies against /jwks (RS256)" "" "" "verification failed"; fi
else record SKIP "jwt" "RS256 signature verify against /jwks" "" "" "PyJWT/cryptography not on host (payload claims asserted above)"; fi

# =============================================================================
section "11. Rate limit + documented-but-not-exercised"
# =============================================================================
if [ "$MODE" = "on" ]; then
  RL_PHONE=$(gen_phone); rl_hit=""
  for i in 1 2 3 4 5 6 7; do
    req POST /api/v1/auth/signup/request "{\"phone\":\"$RL_PHONE\"}"
    [ "$RESP_CODE" = "429" ] && { rl_hit=1; break; }
  done
  if [ -n "$rl_hit" ]; then record PASS "signup" "OTP rate-limit eventually → 429" "429" "429" "per-phone throttle"
  else record WARN "signup" "OTP rate-limit → 429" "" "429" "did not trip within 7 requests (OTP_RATE_PER_HOUR high?)"; fi
else
  record INFO "scope" "429 rate_limited (OTP throttle)" "" "" "NOT-EXERCISED: OTP disabled in this deployment"
fi
record INFO "scope" "503 dependency_unavailable (all endpoints)" "" "" "NOT-EXERCISED: needs a live dep taken down"
record INFO "scope" "413 payload_too_large (kyc/submit)" "" "" "NOT-EXERCISED: requires proxy/body-size limit"
record INFO "scope" "gRPC server (auth.proto, :20001)" "" "" "NOT-COVERED: HTTP harness; needs grpcurl + proto"

# EXIT trap writes result.json + sets the exit code
