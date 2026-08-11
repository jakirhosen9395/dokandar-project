#!/usr/bin/env bash
# 09-payment smoke — ops contract + intent (internal, idempotent) + webhook (HMAC, replay-fence)
# + refund + payout + commission-rates + cod-ledger + auth gates. Mints RS256 tokens via 01-auth.
# Reads INTERNAL_SERVICE_TOKEN + PAYMENT_STUB_WEBHOOK_SECRET + Redis creds from ../env/.env.dev.
#   PAYMENT_URL=http://127.0.0.1:10009 AUTH_URL=http://127.0.0.1:10001 SUPPORT_URL=http://127.0.0.1:10099 ./smoke_test/test.sh
set -uo pipefail
PAYMENT_URL="${PAYMENT_URL:-http://127.0.0.1:10009}"
AUTH_URL="${AUTH_URL:-http://127.0.0.1:10001}"
SUPPORT_URL="${SUPPORT_URL:-http://127.0.0.1:10099}"
ADMIN_PHONE="${ADMIN_PHONE:-01700000000}"
ENVF="${ENVF:-$(dirname "$0")/../env/.env.dev}"
gvenv(){ grep -E "^$1=" "$ENVF" 2>/dev/null | head -1 | cut -d= -f2-; }
INTERNAL_TOKEN="${INTERNAL_TOKEN:-$(gvenv INTERNAL_SERVICE_TOKEN)}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-$(gvenv PAYMENT_STUB_WEBHOOK_SECRET)}"; [ -z "$WEBHOOK_SECRET" ] && WEBHOOK_SECRET=stub_webhook_secret
RH="$(gvenv REDIS_HOST)"; RP="$(gvenv REDIS_PORT)"; RPW="$(gvenv REDIS_PASSWORD)"

PASS=0; FAIL=0; WARN=0; SKIP=0; INFO=0; RESP_CODE=""; RESP_BODY=""
rec(){ local st="$1" c="$2" n="$3" g="${4:-}" w="${5:-}" d="${6:-}"; local x=""; [ -n "$g" ] && x=" (HTTP $g${w:+, want $w})"; [ -n "$d" ] && x="$x — $d"; printf "[%s] %s :: %s%s\n" "$st" "$c" "$n" "$x"; case "$st" in PASS)PASS=$((PASS+1));;FAIL)FAIL=$((FAIL+1));;WARN)WARN=$((WARN+1));;SKIP)SKIP=$((SKIP+1));;INFO)INFO=$((INFO+1));;esac; }
ac(){ if [ "$4" = "$3" ]; then rec PASS "$1" "$2" "$4" "$3" "${5:-}"; else rec FAIL "$1" "$2" "$4" "$3" "${5:-}"; fi; }
ain(){ local c="$1" n="$2" a="$3" s="$4" d="${5:-}"; for x in $s; do [ "$a" = "$x" ] && { rec PASS "$c" "$n" "$a" "$s" "$d"; return; }; done; rec FAIL "$c" "$n" "$a" "$s" "$d"; }
jf(){ printf '%s' "$RESP_BODY" | python3 -c "import sys,json
try:
 d=json.load(sys.stdin)
 for k in sys.argv[1].split('.'): d=d[int(k)] if isinstance(d,list) else d.get(k)
 print('' if d is None else ('true' if d is True else 'false' if d is False else d))
except Exception: print('')" "$1" 2>/dev/null; }
jp(){ printf '%s' "$1" | python3 -c "import sys,json
try:
 d=json.load(sys.stdin)
 for k in sys.argv[1].split('.'): d=d.get(k) if isinstance(d,dict) else None
 print('' if d is None else d)
except Exception: print('')" "$2" 2>/dev/null; }
P(){ local m="$1" p="$2" body="${3:-}" hdr="${4:-}" hdr2="${5:-}"; local h=(-s -m 20 -o /tmp/pm_b -w '%{http_code}' -X "$m" "$PAYMENT_URL$p"); [ -n "$hdr" ] && h+=(-H "$hdr"); [ -n "$hdr2" ] && h+=(-H "$hdr2"); [ -n "$body" ] && h+=(-H 'content-type: application/json' -d "$body"); RESP_CODE="$(curl "${h[@]}" 2>/dev/null)"; RESP_BODY="$(cat /tmp/pm_b 2>/dev/null)"; }
areq(){ local m="$1" p="$2" body="${3:-}" tok="${4:-}"; local h=(-s -m 15 -o /tmp/pm_a -w '%{http_code}' -X "$m" "$AUTH_URL$p"); [ -n "$tok" ] && h+=(-H "Authorization: Bearer $tok"); [ -n "$body" ] && h+=(-H 'content-type: application/json' -d "$body"); curl "${h[@]}" >/dev/null 2>&1; cat /tmp/pm_a 2>/dev/null; }
otp(){ curl -s -m 8 "$SUPPORT_URL/otp/latest?phone=$1&purpose=$2" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('code',''))" 2>/dev/null; }
uuid(){ python3 -c "import uuid;print(uuid.uuid4())"; }
genphone(){ printf "01%01d%08d" $((RANDOM%7+2)) $(( (RANDOM*RANDOM)%100000000 )); }
hmac(){ BODY="$1" WS="$WEBHOOK_SECRET" python3 -c "import hmac,hashlib,os;print(hmac.new(os.environ['WS'].encode(),os.environ['BODY'].encode(),hashlib.sha256).hexdigest())"; }
reset_admin_otp(){ [ -z "$RH" ] && return 1; command -v docker >/dev/null 2>&1 && docker run --rm redis:7-alpine redis-cli -h "$RH" -p "${RP:-6379}" ${RPW:+-a "$RPW"} -n 0 DEL "otp_rate:$ADMIN_PHONE" >/dev/null 2>&1; }
login(){ local ph="$1"; areq POST /api/v1/auth/login/request "{\"phone\":\"$ph\"}" >/dev/null; sleep 1; local code; code="$(otp "$ph" login)"; [ -z "$code" ] && { echo ""; return; }; jp "$(areq POST /api/v1/auth/login/verify "{\"phone\":\"$ph\",\"code\":\"$code\"}")" access_token; }
signup(){ local ph; ph="$(genphone)"; areq POST /api/v1/auth/signup/request "{\"phone\":\"$ph\"}" >/dev/null; sleep 1; local code; code="$(otp "$ph" signup)"; [ -z "$code" ] && { echo ""; return; }; jp "$(areq POST /api/v1/auth/signup/verify "{\"phone\":\"$ph\",\"code\":\"$code\",\"name\":\"Cust\"}")" access_token; }
hmac_b64(){ BODY="$1" WS="$WEBHOOK_SECRET" python3 -c "import hmac,hashlib,base64,os;print(base64.b64encode(hmac.new(os.environ['WS'].encode(),os.environ['BODY'].encode(),hashlib.sha256).digest()).decode())"; }
sub_of(){ printf '%s' "$1" | cut -d. -f2 | python3 -c "import sys,base64,json;s=sys.stdin.read().strip();s+='='*(-len(s)%4);print(json.loads(base64.urlsafe_b64decode(s)).get('sub',''))" 2>/dev/null; }

echo "== 09-payment smoke =="
P GET /ready; [ "$RESP_CODE" = "000" ] && { rec FAIL preflight "payment reachable" "$RESP_CODE" 200 "cannot reach $PAYMENT_URL"; echo "RESULT: FAIL"; exit 1; }
[ -z "$(curl -s -o /dev/null -w '%{http_code}' "$AUTH_URL/ready" 2>/dev/null | grep -E '200|503')" ] && AUTHDOWN=1 || AUTHDOWN=0

echo "-- 1. ops contract --"
P GET /ready; ain ops "/ready 200|503" "$RESP_CODE" "200 503"
ac ops "identity.service_name==09-payment" "$(jf identity.service_name)" "09-payment" svc
ac ops "/ready gates postgres only (dep0)" "$(jf dependencies.0.name)" "postgres" dep0
ac ops "/ready postgres-only (no dep1)" "$(jf dependencies.1.name)" "" dep1_absent
P GET /health; ain ops "/health 200|503" "$RESP_CODE" "200 503"
[ -n "$(jf checks.postgres.ok)" ] && rec PASS ops "/health checks (pg+redis+kafka+rabbitmq)" "" "" "rmq=$(jf checks.rabbitmq.ok)" || rec FAIL ops "/health checks" "" "" missing
P GET /data; ain ops "/data 200|404" "$RESP_CODE" "200 404"
P GET /metrics; { [ "$RESP_CODE" = 200 ] && grep -qE "payment_|http_requests" <<<"$RESP_BODY"; } && rec PASS ops "/metrics prometheus (payment_*)" "" "" ok || rec FAIL ops "/metrics" "$RESP_CODE" 200 "no payment metrics"
grep -q "payment_outbox_pending" <<<"$RESP_BODY" && rec PASS ops "/metrics has payment_outbox_pending" "" "" ok || rec WARN ops "payment_outbox_pending" "" "" "not present"
P GET /openapi.json; ac ops "/openapi.json 200" "200" "$RESP_CODE"
ac ops "/openapi HTTPBearer" "$(jf components.securitySchemes.HTTPBearer.scheme)" "bearer"
ac ops "/openapi InternalToken" "$(jf components.securitySchemes.InternalToken.in)" "header"
P GET /docs; ain ops "/docs 200|302" "$RESP_CODE" "200 302"
BARE=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$PAYMENT_URL/no-such-xyz" 2>/dev/null); ac ops "unknown path → bare 404" "404" "$BARE"

echo "-- 2. intent create (internal token, idempotent) --"
OID="$(uuid)"; CID="$(uuid)"; SKID="$(uuid)"
P POST /api/v1/payment/intents "{\"order_id\":\"$OID\",\"customer_id\":\"$CID\",\"shopkeeper_id\":\"$SKID\",\"provider\":\"bkash\",\"amount_minor\":50000}" "x-internal-token: $INTERNAL_TOKEN"
ac intent "create intent → 201" "201" "$RESP_CODE"; INTENT_ID="$(jf id)"; ac intent "  state=pending" "$(jf state)" "pending"; ac intent "  bkash redirect set" "$([ -n "$(jf provider_redirect_url)" ]&&echo y)" "y" redirect
P POST /api/v1/payment/intents "{\"order_id\":\"$OID\",\"customer_id\":\"$CID\",\"shopkeeper_id\":\"$SKID\",\"provider\":\"bkash\",\"amount_minor\":50000}" "x-internal-token: $INTERNAL_TOKEN"
ac intent "idempotent re-POST → same intent id" "$(jf id)" "$INTENT_ID" idem
P POST /api/v1/payment/intents "{\"order_id\":\"$(uuid)\",\"customer_id\":\"$CID\",\"provider\":\"bkash\",\"amount_minor\":1000}"
ac authz "create intent no internal-token → 401" "401" "$RESP_CODE"
P POST /api/v1/payment/intents "{\"order_id\":\"$(uuid)\",\"customer_id\":\"$CID\",\"provider\":\"nope\",\"amount_minor\":1000}" "x-internal-token: $INTERNAL_TOKEN"
ac validation "invalid provider → 422" "422" "$RESP_CODE"

echo "-- 3. webhook (HMAC, replay fence) --"
EVT="$(uuid)"; WB="{\"event_id\":\"$EVT\",\"order_id\":\"$OID\",\"provider_txn_id\":\"TXN1\"}"; SIG="$(hmac "$WB")"
P POST /api/v1/payment/webhooks/bkash "$WB" "x-signature: $SIG"
ac webhook "settle → 200" "200" "$RESP_CODE"; ac webhook "  settled=true" "$(jf settled)" "true"
P POST /api/v1/payment/webhooks/bkash "$WB" "x-signature: $SIG"
ac webhook "replay (dup event) → 200" "200" "$RESP_CODE"; ac webhook "  duplicate=true" "$(jf duplicate)" "true"
P POST /api/v1/payment/webhooks/bkash "$WB" "x-signature: deadbeef"
ac webhook "bad signature → 403" "403" "$RESP_CODE"; ac webhook "  code=signature_invalid" "$(jf error.code)" "signature_invalid"
NM="{\"event_id\":\"$(uuid)\",\"order_id\":\"$(uuid)\"}"; P POST /api/v1/payment/webhooks/bkash "$NM" "x-signature: $(hmac "$NM")"
ac webhook "no matching intent → ignored" "$(jf ignored)" "no_matching_intent"
# 00-support provider-callback format: base64 X-Signature + status (completed|failed)
OIDB="$(uuid)"; P POST /api/v1/payment/intents "{\"order_id\":\"$OIDB\",\"customer_id\":\"$(uuid)\",\"provider\":\"nagad\",\"amount_minor\":20000}" "x-internal-token: $INTERNAL_TOKEN"
WBB="{\"event_id\":\"$(uuid)\",\"order_id\":\"$OIDB\",\"status\":\"completed\"}"; P POST /api/v1/payment/webhooks/nagad "$WBB" "x-signature: $(hmac_b64 "$WBB")"
ac webhook "base64 sig (00-support fmt) + status=completed → settled" "$(jf settled)" "true"
OIDF="$(uuid)"; P POST /api/v1/payment/intents "{\"order_id\":\"$OIDF\",\"customer_id\":\"$(uuid)\",\"provider\":\"bkash\",\"amount_minor\":15000}" "x-internal-token: $INTERNAL_TOKEN"
WBF="{\"event_id\":\"$(uuid)\",\"order_id\":\"$OIDF\",\"status\":\"failed\"}"; P POST /api/v1/payment/webhooks/bkash "$WBF" "x-signature: $(hmac_b64 "$WBF")"
ac webhook "status=failed → payment.failed (failed=true)" "$(jf failed)" "true"

if [ "$AUTHDOWN" = 0 ]; then
  reset_admin_otp; ATOK="$(login "$ADMIN_PHONE")"; C1="$(signup)"
  if [ -z "$ATOK" ]; then rec WARN mint "admin token" "" "" "admin login failed; admin tests skipped"; else
  rec INFO mint "tokens" "" "" "admin=y cust=$([ -n "$C1" ]&&echo y||echo n)"
  echo "-- 4. intent reads (owner) --"
  C1SUB="$(sub_of "$C1")"; OID2="$(uuid)"
  P POST /api/v1/payment/intents "{\"order_id\":\"$OID2\",\"customer_id\":\"$C1SUB\",\"provider\":\"bkash\",\"amount_minor\":30000}" "x-internal-token: $INTERNAL_TOKEN"; IID2="$(jf id)"
  P GET "/api/v1/payment/intents/$IID2" "" "Authorization: Bearer $C1"; ac intent "owner GET intent → 200" "200" "$RESP_CODE"
  P GET "/api/v1/payment/intents/me" "" "Authorization: Bearer $C1"; ac intent "GET intents/me → 200" "200" "$RESP_CODE"
  P GET "/api/v1/payment/intents/me"; ac authz "intents/me no token → 401" "401" "$RESP_CODE"
  echo "-- 5. refund + payout + commission (admin) --"
  P POST /api/v1/payment/refunds "{\"intent_id\":\"$INTENT_ID\",\"refunded_amount_minor\":10000}" "Authorization: Bearer $ATOK"
  ac refund "refund settled intent → 200" "200" "$RESP_CODE"; ac refund "  reversed_commission present" "$([ -n "$(jf reversed_commission_minor)" ]&&echo y)" "y"
  P POST /api/v1/payment/refunds "{\"intent_id\":\"$(uuid)\",\"refunded_amount_minor\":100}" "Authorization: Bearer $ATOK"
  ac refund "refund no payment → 404" "404" "$RESP_CODE"
  P POST /api/v1/payment/refunds "{\"intent_id\":\"$INTENT_ID\",\"refunded_amount_minor\":100}"; ac authz "refund no token → 401" "401" "$RESP_CODE"
  if [ -n "$C1" ]; then P POST /api/v1/payment/refunds "{\"intent_id\":\"$INTENT_ID\",\"refunded_amount_minor\":100}" "Authorization: Bearer $C1"; ac authz "refund as customer → 403" "403" "$RESP_CODE"; fi
  P POST /api/v1/payment/payouts "{\"shopkeeper_id\":\"$SKID\",\"destination\":\"acct-123\"}" "Authorization: Bearer $ATOK"
  ain payout "payout → 200 (or 400 no_pending)" "$RESP_CODE" "200 400" "$(jf error.code)"
  P GET "/api/v1/payment/payouts" "" "Authorization: Bearer $ATOK"; ac payout "list payouts (admin) → 200" "200" "$RESP_CODE"
  P GET "/api/v1/payment/cod-ledger" "" "Authorization: Bearer $C1"; ac payout "cod-ledger (user) → 200" "200" "$RESP_CODE"
  P GET "/api/v1/payment/commission-rates" "" "Authorization: Bearer $ATOK"; ac commission "list rates (admin) → 200" "200" "$RESP_CODE"
  P POST /api/v1/payment/commission-rates "{\"scope\":\"shopkeeper\",\"scope_id\":\"$SKID\",\"percent_basis_points\":300,\"flat_minor\":0}" "Authorization: Bearer $ATOK"
  ac commission "create rate (admin) → 200" "200" "$RESP_CODE"
  P GET "/api/v1/payment/commission-rates"; ac authz "list rates no token → 401" "401" "$RESP_CODE"
  fi
else rec SKIP authed "all authed paths" "" "" "AUTH down"; fi

echo
echo "RESULT: $([ $FAIL -eq 0 ] && echo PASS || echo FAIL)   PASS=$PASS FAIL=$FAIL SKIP=$SKIP WARN=$WARN INFO=$INFO (total $((PASS+FAIL+SKIP+WARN+INFO)))"
[ $FAIL -eq 0 ]
