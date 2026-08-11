#!/usr/bin/env bash
# =============================================================================
# DOKANDAR Notification Service (14-notification) — smoke / contract harness
# -----------------------------------------------------------------------------
# Node 24 / Fastify 5 · event-to-user fan-out · MongoDB inbox · REST :3000 → ext 10014.
# Exercises the five ops endpoints + the customer-facing inbox/preferences API + a
# best-effort WebSocket auth probe, asserting the documented contract:
#   * /ready gates MongoDB ONLY (dep[0]=mongodb, NO dep[1]) — the §16-b landmine
#   * /health reports mongodb,redis,kafka,rabbitmq,nats,mongo_logs,apm
#   * bare-404 (zero bytes, no content-type), bearerJwt scheme, pretty-JSON identity
#   * inbox/preferences require a real RS256 customer token, minted from AUTH (AUTH_URL)
#     with OTPs recovered from SUPPORT (SUPPORT_URL) — robust support→docker→ssh recovery.
#
# Design (mirrors 06-cart/10-wallet): `set -uo pipefail` (a failed assertion is data,
# not an abort); stdlib python3 for JSON; infra/auth down is reported SKIP/WARN, never
# FAIL. Prints a PASS/FAIL counter and a final 'N/0' summary; exit 0 iff FAIL==0.
#
#   NOTIF_URL=http://127.0.0.1:10014 AUTH_URL=http://127.0.0.1:10001 \
#   SUPPORT_URL=http://127.0.0.1:10099 ./smoke_test/test.sh
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- configuration (env-overridable) ----------------------------------------
NOTIF_URL="${NOTIF_URL:-http://127.0.0.1:10014}"
AUTH_URL="${AUTH_URL:-http://127.0.0.1:10001}"
SUPPORT_URL="${SUPPORT_URL:-http://127.0.0.1:10099}"
AUTH_CONTAINER="${AUTH_CONTAINER:-dokandar_auth_service_dev}"
TIMEOUT="${TIMEOUT:-15}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-30}"
AUTH_SSH="${AUTH_SSH:-}"; AUTH_SSH_KEY="${AUTH_SSH_KEY:-}"
AUTH_SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
[ -n "$AUTH_SSH_KEY" ] && AUTH_SSH_OPTS="-i $AUTH_SSH_KEY $AUTH_SSH_OPTS"

PASS=0; FAIL=0; WARN=0; SKIP=0; INFO=0
RESP_CODE=""; RESP_BODY=""; RESP_SIZE=""; RESP_CT=""
BODYF="$(mktemp)"
trap 'rm -f "$BODYF" 2>/dev/null || true' EXIT

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''; fi

# --- recording + assertions --------------------------------------------------
record() {
  local st="$1" cat="$2" name="$3" got="${4:-}" want="${5:-}" det="${6:-}" sym col x=""
  case "$st" in
    PASS) sym="[PASS]"; col=$GREEN; PASS=$((PASS+1));;
    FAIL) sym="[FAIL]"; col=$RED;   FAIL=$((FAIL+1));;
    SKIP) sym="[SKIP]"; col=$YELLOW; SKIP=$((SKIP+1));;
    WARN) sym="[WARN]"; col=$YELLOW; WARN=$((WARN+1));;
    INFO) sym="[INFO]"; col=$BLUE;  INFO=$((INFO+1));;
    *)    sym="[????]"; col=$NC;;
  esac
  [ -n "$got" ] && x=" (HTTP $got${want:+, want $want})"
  [ -n "$det" ] && x="$x — $det"
  printf '%b%s %s :: %s%s%b\n' "$col" "$sym" "$cat" "$name" "$x" "$NC"
}
assert_code() { if [ "$4" = "$3" ]; then record PASS "$1" "$2" "$4" "$3" "${5:-}"; else record FAIL "$1" "$2" "$4" "$3" "${5:-}"; fi; }
assert_eq()   { local lbl="${5:-value}"; if [ "$3" = "$4" ]; then record PASS "$1" "$2" "" "" "$lbl='$3'"; else record FAIL "$1" "$2" "" "" "$lbl='$3' want '$4'"; fi; }
assert_nonempty() { if [ -n "$3" ]; then record PASS "$1" "$2" "" "" "${4:-field} present"; else record FAIL "$1" "$2" "" "" "${4:-field} missing/empty"; fi; }
assert_in()   { local c="$1" n="$2" a="$3" set="$4" d="${5:-}"; local x; for x in $set; do [ "$a" = "$x" ] && { record PASS "$c" "$n" "$a" "$set" "$d"; return; }; done; record FAIL "$c" "$n" "$a" "$set" "$d"; }

# --- HTTP + JSON helpers -----------------------------------------------------
# _http BASE METHOD PATH [BODY] [TOKEN] [IDEMPOTENCY-KEY] [TIMEOUT]
_http() {
  local base="$1" m="$2" p="$3" body="${4:-}" tok="${5:-}" idem="${6:-}" to="${7:-$TIMEOUT}"
  local a=(-s -S -m "$to" -o "$BODYF" -w '%{http_code} %{size_download} %{content_type}' -X "$m" "$base$p")
  [ -n "$body" ] && a+=(-H 'Content-Type: application/json' --data "$body")
  [ -n "$tok" ]  && a+=(-H "Authorization: Bearer $tok")
  [ -n "$idem" ] && a+=(-H "Idempotency-Key: $idem")
  local out rest
  out=$(curl "${a[@]}" 2>/dev/null) || out="000 0 "
  RESP_CODE=${out%% *}; rest=${out#* }; RESP_SIZE=${rest%% *}; RESP_CT=${rest#* }
  [ -z "$RESP_CODE" ] && RESP_CODE="000"
  RESP_BODY=$(cat "$BODYF" 2>/dev/null || true)
}
req()  { _http "$NOTIF_URL" "$@"; }   # service under test
areq() { _http "$AUTH_URL" "$@"; }    # auth (token minting)

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
gen_phone() { printf "017%08d" $(( (RANDOM*RANDOM) % 100000000 )); }

# --- OTP recovery: support → docker logs → SSH -------------------------------
support_reachable() { [ -n "$SUPPORT_URL" ] && [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$SUPPORT_URL/health" 2>/dev/null)" = "200" ]; }
read_otp_support() {
  [ -n "$SUPPORT_URL" ] || return 0
  curl -s -m 8 "$SUPPORT_URL/otp/latest?phone=$1&purpose=$2" 2>/dev/null | python3 -c '
import sys, json
try: print(json.load(sys.stdin).get("code", ""))
except Exception: print("")' 2>/dev/null
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
otp_code_for() {
  local i code=""
  for i in $(seq 1 12); do
    code=$(read_otp_logs "$1" "$2"); [ -n "$code" ] && { printf '%s' "$code"; return; }; sleep 0.5
  done
  printf '%s' "$code"
}

# --- mint a real RS256 customer token ----------------------------------------
mint() {
  local ph="$1"
  areq POST /api/v1/auth/signup/request "{\"phone\":\"$ph\"}"
  local probe; probe=$(jf status)
  if [ "$probe" = "otp_disabled" ]; then MODE="off"; elif [ "$probe" = "otp_sent" ]; then MODE="on"; else MODE="unknown"; fi
  local code=""
  if [ "$MODE" = "on" ]; then code=$(otp_code_for "$ph" signup); fi
  local body="{\"phone\":\"$ph\",\"name\":\"Notif Tester\",\"role\":\"customer\""
  [ -n "$code" ] && body="$body,\"code\":\"$code\""; body="$body}"
  areq POST /api/v1/auth/signup/verify "$body"
  MINT_CODE="$RESP_CODE"; MINT_ACCESS=""
  [ "$RESP_CODE" = "201" ] && MINT_ACCESS=$(jf access_token)
}

section() { printf '\n%b===== %s =====%b\n' "$BOLD" "$1" "$NC"; }

printf '%bDOKANDAR notification smoke test%b  →  %s\n' "$BOLD" "$NC" "$NOTIF_URL"
printf 'auth=%s  support=%s\n' "$AUTH_URL" "$SUPPORT_URL"

# --- preflight ---------------------------------------------------------------
req GET /ready
if [ "$RESP_CODE" = "000" ]; then
  record FAIL preflight "GET /ready reachable" "$RESP_CODE" "200" "cannot reach $NOTIF_URL — on the box use http://127.0.0.1:10014"
  echo; echo "RESULT: FAIL — service unreachable"; exit 1
fi
CV=$(jf identity.code_version); TEN=$(jf identity.tenant); ENVN=$(jf identity.env)
record INFO preflight "service identity" "" "" "code_version=$CV tenant=$TEN env=$ENVN"
areq GET /ready
if [ "$RESP_CODE" = "000" ]; then AUTH_DOWN=1; record WARN preflight "AUTH /ready reachable" "$RESP_CODE" "200" "token minting (inbox/preferences) skipped"; else AUTH_DOWN=0; fi

# =============================================================================
section "1. Operational / contract surface"
# =============================================================================
req GET /ready
assert_in ops "/ready 200|503" "$RESP_CODE" "200 503"
if [ "$RESP_CODE" = "200" ]; then assert_eq ops "/ready status==ready when 200" "$(jf status)" "ready" status
elif [ "$RESP_CODE" = "503" ]; then record WARN ops "/ready is 503 (a gating dep — mongodb — is down)" "$RESP_CODE" "200" "status=$(jf status)"; fi
assert_eq ops "/ready identity.service_name==14-notification" "$(jf identity.service_name)" "14-notification" service_name
assert_eq ops "/ready identity.code_version==14-notification" "$(jf identity.code_version)" "14-notification" code_version
# THE §16-b signature check: 14-notification gates MongoDB ONLY (cart=mongo+redis, wallet=postgres).
assert_eq ops "/ready gates on mongodb ONLY (dep[0])" "$(jf dependencies.0.name)" "mongodb" "dep[0]"
assert_eq ops "/ready has NO second dependency (mongo-only gate)" "$(jf dependencies.1.name)" "" "dep[1]"

req GET /health "" "" "" "" "$HEALTH_TIMEOUT"
assert_in ops "/health 200|503" "$RESP_CODE" "200 503"
[ "$RESP_CODE" = "200" ] && assert_eq ops "/health status==healthy when 200" "$(jf status)" "healthy" status
# Mongo is the core check; the rest are diagnostic and MUST be present but never gate.
assert_nonempty ops "/health checks.mongodb.ok present" "$(jf checks.mongodb.ok)" "mongodb"
for dep in redis kafka rabbitmq nats mongo_logs apm; do
  ok=$(jf "checks.$dep.ok")
  if [ -z "$ok" ]; then record FAIL ops "/health has check: $dep" "" "" "missing from checks{}"
  elif [ "$ok" = "True" ]; then record INFO ops "/health dep $dep" "" "" "ok"
  else record WARN ops "/health dep $dep DOWN (non-gating)" "" "" "ok=$ok"; fi
done
assert_eq ops "/health observability.apm_service_name==14-notification" "$(jf observability.apm_service_name)" "14-notification" apm_service_name

req GET /data
if [ "$RESP_CODE" = "200" ]; then record PASS ops "/data → 200 (snapshot + identity)" "200" "200" "kind=$(jf kind) service=$(jf service)"
  assert_eq ops "/data identity.service_name==14-notification" "$(jf identity.service_name)" "14-notification" service_name
elif [ "$RESP_CODE" = "404" ]; then assert_eq ops "/data 404 → no_snapshot" "$(jf error.code)" "no_snapshot" code
else record FAIL ops "/data 200|404" "$RESP_CODE" "200|404"; fi

req GET /metrics
{ [ "$RESP_CODE" != "200" ] || [ "${RESP_SIZE:-0}" = "0" ]; } && { sleep 0.5; req GET /metrics; }
assert_code ops "GET /metrics → 200" "200" "$RESP_CODE"
# Grep metric NAMES — prom-client emits # HELP/# TYPE for every REGISTERED metric even
# with zero series, so this is correct on a fresh box (no Kafka events fired). Do NOT
# require a {channel=...} value line — those series do not exist during smoke.
for metric in http_requests_total http_request_duration_seconds \
              notification_sent_total notification_dedup_hits_total \
              notification_websocket_connections notification_channel_queue_depth; do
  if grep -q "$metric" <<<"$RESP_BODY"; then record PASS ops "/metrics exposes $metric" "" "" "present"
  else record FAIL ops "/metrics exposes $metric" "" "" "missing"; fi
done
# The service="14-notification" label only rides DATA series (no setDefaultLabels) — absent
# without traffic. WARN, never FAIL (06-cart/10-wallet parity).
grep -q 'service="14-notification"' <<<"$RESP_BODY" && record PASS ops "/metrics service label observed" "" "" "present" \
  || record WARN ops "/metrics service label" "" "" "service=\"14-notification\" rides data series only (no notifications fired during smoke)"
# No outbox → there MUST be no *_outbox_pending gauge (terminal consumer).
grep -q 'outbox_pending' <<<"$RESP_BODY" && record FAIL ops "/metrics has NO *_outbox_pending (terminal consumer)" "" "" "found an outbox gauge — should not exist" \
  || record PASS ops "/metrics has NO *_outbox_pending (terminal consumer)" "" "" "absent (correct)"

req GET /openapi.json
assert_code ops "GET /openapi.json → 200" "200" "$RESP_CODE"
assert_nonempty ops "/openapi.json has openapi version" "$(jf openapi)" "openapi"
assert_eq ops "/openapi.json wires bearerJwt scheme" "$(jf components.securitySchemes.bearerJwt.scheme)" "bearer" scheme
assert_eq ops "/openapi.json title" "$(jf info.title)" "DOKANDAR Notification Service" title
# Spot-check the documented business paths are in the spec (full route-vs-spec diff is a CI job).
OPENAPI_BODY="$RESP_BODY"
for path in /api/v1/notification/inbox /api/v1/notification/preferences; do
  if printf '%s' "$OPENAPI_BODY" | python3 -c "import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if any(p.startswith('$path') for p in (d.get('paths') or {})) else 1)" 2>/dev/null; then
    record PASS ops "/openapi.json documents $path" "" "" "present"
  else record WARN ops "/openapi.json documents $path" "" "" "not found in openapi.paths"; fi
done

req GET /docs
assert_in ops "GET /docs → 200|301|302|303" "$RESP_CODE" "200 301 302 303"
case "$RESP_CT" in *text/html*) record PASS ops "/docs is text/html" "" "" "$RESP_CT";; *) record INFO ops "/docs content-type" "" "" "got '$RESP_CT'";; esac

# bare 404 — zero bytes, no body, NO content-type
BARE_CODE=$(curl -s -m 8 -o "$BODYF" -w '%{http_code}' "$NOTIF_URL/no-such-route-xyz" 2>/dev/null)
BARE_SIZE=$(wc -c < "$BODYF" 2>/dev/null | tr -d ' ')
BARE_CT=$(curl -s -m 8 -o /dev/null -D - "$NOTIF_URL/no-such-route-xyz" 2>/dev/null | grep -i '^content-type:' | tr -d '\r')
assert_code ops "unmapped path → 404" "404" "$BARE_CODE"
assert_eq ops "  bare 404 body is zero-byte" "${BARE_SIZE:-x}" "0" bytes
if [ -z "$BARE_CT" ]; then record PASS ops "  bare 404 has NO Content-Type" "" "" "absent (correct)"
else record FAIL ops "  bare 404 has NO Content-Type" "" "" "got '$BARE_CT'"; fi

# =============================================================================
section "2. Auth gate (key sanity)"
# =============================================================================
req GET /api/v1/notification/inbox
assert_code authz "GET /inbox no token → 401" "401" "$RESP_CODE"
assert_nonempty authz "  401 carries an error.code" "$(jf error.code)" "error.code"
assert_nonempty authz "  401 carries a request_id" "$(jf error.request_id)" "request_id"
req GET /api/v1/notification/inbox "" "garbage.token.value"
assert_code authz "GET /inbox malformed token → 401" "401" "$RESP_CODE"

# =============================================================================
section "3. Mint a customer + KEY-SANITY gate"
# =============================================================================
TOKEN=""; MODE="unknown"
if [ "${AUTH_DOWN:-0}" = "1" ]; then
  record SKIP mint "customer minting" "" "" "AUTH unreachable at $AUTH_URL"
else
  PH=$(gen_phone)
  if support_reachable; then record INFO mint "OTP recovery channel" "" "" "support ($SUPPORT_URL)"
  elif command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$AUTH_CONTAINER"; then record INFO mint "OTP recovery channel" "" "" "docker-local"
  elif [ -n "$AUTH_SSH" ]; then record INFO mint "OTP recovery channel" "" "" "ssh"
  else record INFO mint "OTP recovery channel" "" "" "none (OK if auth OTP is disabled)"; fi
  mint "$PH"
  record INFO mint "OTP mode (auth)" "" "" "MODE=$MODE"
  if [ "$MINT_CODE" = "201" ] && [ -n "$MINT_ACCESS" ]; then
    TOKEN="$MINT_ACCESS"
    record PASS mint "customer minted (auth signup → 201)" "201" "201" "phone=$PH"
    req GET /api/v1/notification/inbox "" "$TOKEN"
    if [ "$RESP_CODE" = "200" ]; then record PASS mint "notification accepts auth-issued token (RS256 key aligned)" "200" "200" "key OK"
    elif [ "$RESP_CODE" = "401" ]; then TOKEN=""
      record FAIL mint "notification accepts auth-issued token" "401" "200" "REJECTED a fresh auth token → JWT_PUBLIC_KEY_B64 drift vs auth. Copy auth's public key into 14-notification/env and restart. Authed sections skipped."
    else record WARN mint "/inbox with fresh token" "$RESP_CODE" "200" "unexpected"; fi
  else
    record WARN mint "customer minting" "$MINT_CODE" "201" "could not mint (auth/OTP) — authed sections skipped: $(jf error.code)"
  fi
fi

# =============================================================================
section "4. Inbox (read + mark-read + read-all)"
# =============================================================================
if [ -n "$TOKEN" ]; then
  req GET /api/v1/notification/inbox "" "$TOKEN"
  assert_code inbox "GET /inbox → 200" "200" "$RESP_CODE"
  ITEMS0=$(jf items.0.kind)
  record INFO inbox "inbox state" "" "" "first item kind='${ITEMS0:-<empty inbox>}'"
  # items[] must be an array (empty OK). Confirm the key parses as a list.
  if printf '%s' "$RESP_BODY" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if isinstance(d.get("items"), list) else 1)' 2>/dev/null; then
    record PASS inbox "  response has items[] array (empty OK)" "" "" "ok"
  else record FAIL inbox "  response has items[] array" "" "" "items[] missing or not a list"; fi

  req GET "/api/v1/notification/inbox?page=1&size=10" "" "$TOKEN"
  assert_in inbox "GET /inbox paged (page/size) → 200" "$RESP_CODE" "200"

  # mark-read of the first item if any, else a synthetic id (tolerate 404/200).
  FIRST_ID=$(jf items.0.id); [ -z "$FIRST_ID" ] && FIRST_ID=$(printf '%s' "$RESP_BODY" | jget items.0._id)
  if [ -n "$FIRST_ID" ]; then
    req POST "/api/v1/notification/inbox/$FIRST_ID/read" "" "$TOKEN"
    assert_in inbox "POST /inbox/:id/read → 200" "$RESP_CODE" "200"
  else
    req POST "/api/v1/notification/inbox/000000000000000000000000/read" "" "$TOKEN"
    assert_in inbox "POST /inbox/:id/read (empty inbox) → 200|404" "$RESP_CODE" "200 404"
  fi

  req POST /api/v1/notification/inbox/read-all "" "$TOKEN"
  assert_code inbox "POST /inbox/read-all → 200" "200" "$RESP_CODE"
  UPD=$(jf updated); [ -z "$UPD" ] && UPD=$(jf modified)
  record INFO inbox "read-all result" "" "" "updated='${UPD:-n/a}' (0 OK on an empty inbox)"
else
  record SKIP inbox "inbox suite" "" "" "no aligned customer token"
fi

# =============================================================================
section "5. Preferences (GET defaults → PUT → GET reflects)"
# =============================================================================
if [ -n "$TOKEN" ]; then
  req GET /api/v1/notification/preferences "" "$TOKEN"
  assert_code prefs "GET /preferences → 200 (defaults)" "200" "$RESP_CODE"
  # channels map per architecture §3 (sms/push/email/whatsapp booleans). The exact
  # default values are the agent's call — assert the SHAPE (all four keys present).
  MISSING=""
  for ch in sms push email whatsapp; do
    v=$(jf "channels.$ch"); [ -z "$v" ] && v=$(jf "$ch")
    [ -z "$v" ] && MISSING="$MISSING $ch"
  done
  [ -z "$MISSING" ] && record PASS prefs "  channels{sms,push,email,whatsapp} all present" "" "" "ok" \
    || record WARN prefs "  channels keys present" "" "" "absent:$MISSING (default-on may render true; key may live under channels{})"

  req PUT /api/v1/notification/preferences '{"channels":{"sms":false,"push":true,"email":true,"whatsapp":false}}' "$TOKEN"
  # Some implementations take a flat body; retry flat on a 422.
  if [ "$RESP_CODE" = "422" ]; then
    req PUT /api/v1/notification/preferences '{"sms":false,"push":true,"email":true,"whatsapp":false}' "$TOKEN"
  fi
  assert_code prefs "PUT /preferences → 200" "200" "$RESP_CODE"

  req GET /api/v1/notification/preferences "" "$TOKEN"
  assert_code prefs "GET /preferences (after PUT) → 200" "200" "$RESP_CODE"
  SMS_NOW=$(jf channels.sms); [ -z "$SMS_NOW" ] && SMS_NOW=$(jf sms)
  EMAIL_NOW=$(jf channels.email); [ -z "$EMAIL_NOW" ] && EMAIL_NOW=$(jf email)
  if [ "$SMS_NOW" = "False" ] && [ "$EMAIL_NOW" = "True" ]; then
    record PASS prefs "  GET reflects the PUT (sms=false,email=true)" "" "" "sms=$SMS_NOW email=$EMAIL_NOW"
  else
    record WARN prefs "  GET reflects the PUT" "" "" "sms='$SMS_NOW' email='$EMAIL_NOW' (schema may differ — verify by hand)"
  fi

  # validation: a non-boolean channel value should be 422 (Fastify schema).
  req PUT /api/v1/notification/preferences '{"channels":{"sms":"yes"}}' "$TOKEN"
  assert_in prefs "PUT bad channel value → 422|400" "$RESP_CODE" "422 400"
else
  record SKIP prefs "preferences suite" "" "" "no aligned customer token"
fi

# =============================================================================
section "6. WebSocket auth probe (best-effort)"
# =============================================================================
WS_PATH="/api/v1/notification/ws/inbox"
WS_HTTP="${NOTIF_URL#http}"; WS_URL="ws${WS_HTTP}${WS_PATH}"
ws_client=""
command -v websocat >/dev/null 2>&1 && ws_client="websocat"
[ -z "$ws_client" ] && command -v wscat >/dev/null 2>&1 && ws_client="wscat"

if [ -n "$ws_client" ] && [ -n "$TOKEN" ]; then
  # WITH token → expect an upgrade (the client connects and we close immediately).
  if [ "$ws_client" = "websocat" ]; then
    if printf '' | timeout 6 websocat -1 -H "Authorization: Bearer $TOKEN" "$WS_URL" >/dev/null 2>&1; then
      record PASS ws "WS upgrade WITH token → connected" "" "" "$ws_client"
    else record WARN ws "WS upgrade WITH token" "" "" "no clean upgrade (server may push then idle; verify by hand)"; fi
    # WITHOUT token → expect refusal (non-101 / immediate close).
    if printf '' | timeout 6 websocat -1 "$WS_URL" >/dev/null 2>&1; then
      record WARN ws "WS upgrade WITHOUT token → should be refused" "" "" "connected unexpectedly — verify auth-on-upgrade by hand"
    else record PASS ws "WS upgrade WITHOUT token → refused" "" "" "fail-closed"; fi
  else
    record SKIP ws "WS probe" "" "" "wscat present but non-scriptable here — verify by hand"
  fi
else
  # Fallback: curl the Upgrade handshake (best-effort; not a strict assertion).
  NO_TOK_CODE=$(curl -s -m 6 -o /dev/null -w '%{http_code}' \
    -H "Connection: Upgrade" -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    "$NOTIF_URL$WS_PATH" 2>/dev/null)
  if [ -n "$TOKEN" ]; then
    WITH_TOK_CODE=$(curl -s -m 6 -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer $TOKEN" -H "Connection: Upgrade" -H "Upgrade: websocket" \
      -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
      "$NOTIF_URL$WS_PATH" 2>/dev/null)
    record INFO ws "WS handshake probe (curl fallback)" "" "" "no-token→$NO_TOK_CODE with-token→$WITH_TOK_CODE (101=upgraded, 401/4xx=refused)"
  fi
  # Without a real WS client we can only soft-check that a no-token upgrade is NOT 101.
  if [ "$NO_TOK_CODE" = "401" ] || [ "$NO_TOK_CODE" = "403" ] || [ "$NO_TOK_CODE" = "400" ]; then
    record PASS ws "WS upgrade WITHOUT token → refused (curl fallback)" "$NO_TOK_CODE" "" "non-101"
  elif [ "$NO_TOK_CODE" = "101" ]; then
    record WARN ws "WS upgrade WITHOUT token → 101" "$NO_TOK_CODE" "" "upgraded without a token — verify auth-on-upgrade by hand"
  else
    record SKIP ws "WS probe" "" "" "no websocat/wscat installed; curl gave $NO_TOK_CODE — install websocat to exercise the upgrade"
  fi
fi

# =============================================================================
echo
TOTAL=$((PASS+FAIL+SKIP+WARN+INFO))
printf '%b===== RESULT: %s   PASS=%d FAIL=%d SKIP=%d WARN=%d INFO=%d  (%d/%d) =====%b\n' \
  "$BOLD" "$([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL)" "$PASS" "$FAIL" "$SKIP" "$WARN" "$INFO" "$PASS" "$((PASS+FAIL))" "$NC"
[ "$FAIL" -eq 0 ]
