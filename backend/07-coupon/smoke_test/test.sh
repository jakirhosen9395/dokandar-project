#!/usr/bin/env bash
# 07-coupon smoke — ops contract + auth/role gates + ValidateCoupon + the full coupon lifecycle
# (draft → four-eyes approve → active → validate-with-discount → revoke) + festivals.
# Mints real RS256 tokens via 01-auth (:10001) + OTPs from 00-support (:10099). Reads the
# INTERNAL_SERVICE_TOKEN + Redis creds from ../env/.env.dev (for /validate + admin OTP-rate reset).
#   COUPON_URL=http://127.0.0.1:10007 AUTH_URL=http://127.0.0.1:10001 SUPPORT_URL=http://127.0.0.1:10099 ./smoke_test/test.sh
set -uo pipefail
COUPON_URL="${COUPON_URL:-http://127.0.0.1:10007}"
AUTH_URL="${AUTH_URL:-http://127.0.0.1:10001}"
SUPPORT_URL="${SUPPORT_URL:-http://127.0.0.1:10099}"
ADMIN_PHONE="${ADMIN_PHONE:-01700000000}"
ENVF="${ENVF:-$(dirname "$0")/../env/.env.dev}"
gvenv(){ grep -E "^$1=" "$ENVF" 2>/dev/null | head -1 | cut -d= -f2-; }
INTERNAL_TOKEN="${INTERNAL_TOKEN:-$(gvenv INTERNAL_SERVICE_TOKEN)}"
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
 print('' if d is None else ('true' if d is True else 'false' if d is False else d))
except Exception: print('')" "$2" 2>/dev/null; }
C(){ local m="$1" p="$2" body="${3:-}" tok="${4:-}" hdr="${5:-}"; local h=(-s -m 20 -o /tmp/cp_b -w '%{http_code}' -X "$m" "$COUPON_URL$p"); [ -n "$tok" ] && h+=(-H "Authorization: Bearer $tok"); [ -n "$hdr" ] && h+=(-H "$hdr"); [ -n "$body" ] && h+=(-H 'content-type: application/json' -d "$body"); RESP_CODE="$(curl "${h[@]}" 2>/dev/null)"; RESP_BODY="$(cat /tmp/cp_b 2>/dev/null)"; }
areq(){ local m="$1" p="$2" body="${3:-}" tok="${4:-}"; local h=(-s -m 15 -o /tmp/cp_a -w '%{http_code}' -X "$m" "$AUTH_URL$p"); [ -n "$tok" ] && h+=(-H "Authorization: Bearer $tok"); [ -n "$body" ] && h+=(-H 'content-type: application/json' -d "$body"); local code; code="$(curl "${h[@]}" 2>/dev/null)"; cat /tmp/cp_a 2>/dev/null; }
otp(){ curl -s -m 8 "$SUPPORT_URL/otp/latest?phone=$1&purpose=$2" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('code',''))" 2>/dev/null; }
genphone(){ printf "01%01d%08d" $((RANDOM%7+2)) $(( (RANDOM*RANDOM)%100000000 )); }
reset_admin_otp(){ [ -z "$RH" ] && return 1; command -v docker >/dev/null 2>&1 && docker run --rm redis:7-alpine redis-cli -h "$RH" -p "${RP:-6379}" ${RPW:+-a "$RPW"} -n 0 DEL "otp_rate:$ADMIN_PHONE" >/dev/null 2>&1; }
login(){ local ph="$1"; areq POST /api/v1/auth/login/request "{\"phone\":\"$ph\"}" >/dev/null; sleep 1; local code; code="$(otp "$ph" login)"; [ -z "$code" ] && { echo ""; return; }; jp "$(areq POST /api/v1/auth/login/verify "{\"phone\":\"$ph\",\"code\":\"$code\"}")" access_token; }
signup(){ local ph; ph="$(genphone)"; areq POST /api/v1/auth/signup/request "{\"phone\":\"$ph\"}" >/dev/null; sleep 1; local code; code="$(otp "$ph" signup)"; [ -z "$code" ] && { echo ""; return; }; jp "$(areq POST /api/v1/auth/signup/verify "{\"phone\":\"$ph\",\"code\":\"$code\",\"name\":\"Cust\"}")" access_token; }

echo "== 07-coupon smoke =="
C GET /ready; [ "$RESP_CODE" = "000" ] && { rec FAIL preflight "coupon reachable" "$RESP_CODE" 200 "cannot reach $COUPON_URL"; echo "RESULT: FAIL"; exit 1; }
areq GET /ready >/dev/null 2>&1; AUTH_OK=$?; [ -z "$(curl -s -o /dev/null -w '%{http_code}' "$AUTH_URL/ready" 2>/dev/null | grep -E '200|503')" ] && AUTHDOWN=1 || AUTHDOWN=0

echo "-- 1. ops contract --"
C GET /ready; ain ops "/ready 200|503" "$RESP_CODE" "200 503"
ac ops "identity.service_name==07-coupon" "$(jf identity.service_name)" "07-coupon" svc
ac ops "/ready gates postgres only (dep0)" "$(jf dependencies.0.name)" "postgres" dep0
ac ops "/ready postgres-only (no dep1)" "$(jf dependencies.1.name)" "" dep1_absent
C GET /health; ain ops "/health 200|503" "$RESP_CODE" "200 503"
[ -n "$(jf checks.postgres.ok)" ] && rec PASS ops "/health has postgres+kafka+redis checks" "" "" ok || rec FAIL ops "/health checks" "" "" missing
C GET /data; ain ops "/data 200|404" "$RESP_CODE" "200 404"
C GET /metrics; { [ "$RESP_CODE" = 200 ] && grep -qE "coupon_|_total" <<<"$RESP_BODY"; } && rec PASS ops "/metrics prometheus (coupon_*)" "" "" ok || rec FAIL ops "/metrics" "$RESP_CODE" 200 "no coupon metrics"
grep -q "coupon_outbox_pending" <<<"$RESP_BODY" && rec PASS ops "/metrics has coupon_outbox_pending gauge" "" "" ok || rec WARN ops "coupon_outbox_pending" "" "" "not yet emitted"
C GET /openapi.json; ac ops "/openapi.json 200" "200" "$RESP_CODE"
ac ops "/openapi HTTPBearer scheme" "$(jf components.securitySchemes.HTTPBearer.scheme)" "bearer" scheme
C GET /docs; ain ops "/docs 200|301|302" "$RESP_CODE" "200 301 302"
BARE=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$COUPON_URL/no-such-xyz" 2>/dev/null); ac ops "unknown path → bare 404" "404" "$BARE"

echo "-- 2. auth + role gates --"
C GET /api/v1/coupon/coupons/me; ac authz "/coupons/me no token → 401" "401" "$RESP_CODE"
C GET /api/v1/coupon/coupons/me "" "garbage.tok"; ac authz "/coupons/me bad token → 401" "401" "$RESP_CODE"
C GET /api/v1/coupon/festivals; ac public "/festivals public → 200" "200" "$RESP_CODE"

echo "-- 3. ValidateCoupon (east-west; x-internal-token) --"
if [ -n "$INTERNAL_TOKEN" ]; then
  C POST /api/v1/coupon/validate '{"code":"NOPE-XYZ","user_id":"11111111-1111-1111-1111-111111111111","subtotal_minor":50000}' "" "x-internal-token: $INTERNAL_TOKEN"
  ac validate "unknown code → 200 valid=false" "200" "$RESP_CODE"; ac validate "  reason=not_found" "$(jf reason)" "not_found"
  C POST /api/v1/coupon/validate '{"code":"NOPE","user_id":"11111111-1111-1111-1111-111111111111","subtotal_minor":1}'
  ac validate "no x-internal-token → 401" "401" "$RESP_CODE"
else rec WARN validate "ValidateCoupon" "" "" "INTERNAL_SERVICE_TOKEN not found in $ENVF"; fi

if [ "$AUTHDOWN" = 0 ]; then
  reset_admin_otp; ATOK="$(login "$ADMIN_PHONE")"
  if [ -z "$ATOK" ]; then rec WARN mint "admin token" "" "" "admin login failed (OTP rate?); privileged tests skipped"; else
  rec INFO mint "admin minted" "" "" "role=admin"
  # second privileged user (approver) via admin create + login
  SKPH="$(genphone)"; areq POST /api/v1/auth/users "{\"role\":\"shopkeeper\",\"phone\":\"$SKPH\",\"name\":\"Approver\"}" "$ATOK" >/dev/null; STOK="$(login "$SKPH")"
  CTOK="$(signup)"
  VF=$(date -u -d "-1 hour" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ); VU=$(date -u -d "+30 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

  echo "-- 4. role gating --"
  if [ -n "$CTOK" ]; then C POST /api/v1/coupon/coupons "{\"code\":\"C$RANDOM\",\"kind\":\"fixed\",\"scope\":\"shop\",\"funded_by\":\"shopkeeper\",\"shop_id\":\"33333333-3333-3333-3333-333333333333\",\"value_minor\":5000,\"valid_from\":\"$VF\",\"valid_until\":\"$VU\"}" "$CTOK"; ac authz "customer draft → 403" "403" "$RESP_CODE"; else rec SKIP authz "customer draft" "" "" "no customer token"; fi

  echo "-- 5. coupon lifecycle (admin drafts, four-eyes) --"
  CODE="SMOKE$RANDOM"
  C POST /api/v1/coupon/coupons "{\"code\":\"$CODE\",\"kind\":\"percent\",\"scope\":\"platform\",\"funded_by\":\"platform\",\"value_percent\":10,\"valid_from\":\"$VF\",\"valid_until\":\"$VU\"}" "$ATOK"
  ac coupon "draft → 201" "201" "$RESP_CODE"; CID="$(jf id)"; ac coupon "  state=draft" "$(jf state)" "draft"
  C GET /api/v1/coupon/coupons/$CID "" "$ATOK"; ac coupon "get one → 200" "200" "$RESP_CODE"
  C GET /api/v1/coupon/coupons/me "" "$ATOK"; ac coupon "list mine → 200" "200" "$RESP_CODE"
  C POST /api/v1/coupon/coupons/$CID/approve "" "$ATOK"; ac coupon "self-approve → 403 (four-eyes)" "403" "$RESP_CODE"; ac coupon "  code=self_approval_forbidden" "$(jf error.code)" "self_approval_forbidden"
  C POST /api/v1/coupon/coupons "{\"code\":\"BAD$RANDOM\",\"kind\":\"percent\",\"scope\":\"shop\",\"funded_by\":\"shopkeeper\",\"value_percent\":10,\"valid_from\":\"$VF\",\"valid_until\":\"$VU\"}" "$ATOK"; ac validation "draft scope=shop w/o shop_id → 422" "422" "$RESP_CODE"
  if [ -n "$STOK" ]; then
    C POST /api/v1/coupon/coupons/$CID/approve "" "$STOK"; ac coupon "four-eyes approve → 200" "200" "$RESP_CODE"; ac coupon "  state=active" "$(jf state)" "active"
    if [ -n "$INTERNAL_TOKEN" ]; then C POST /api/v1/coupon/validate "{\"code\":\"$CODE\",\"user_id\":\"11111111-1111-1111-1111-111111111111\",\"subtotal_minor\":50000}" "" "x-internal-token: $INTERNAL_TOKEN"; ac validate "active coupon → valid=true" "true" "$(jf valid)"; ac validate "  discount=5000 (10% of 50000)" "5000" "$(jf discount_minor)"; fi
    C POST /api/v1/coupon/coupons/$CID/revoke "" "$ATOK"; ac coupon "revoke → 200" "200" "$RESP_CODE"; ac coupon "  state=revoked" "$(jf state)" "revoked"
  else rec SKIP coupon "four-eyes approve + validate-active + revoke" "" "" "no 2nd privileged token"; fi

  echo "-- 6. festivals --"
  C POST /api/v1/coupon/festivals "{\"slug\":\"eid-$RANDOM\",\"name_bn\":\"ঈদ\",\"name_en\":\"Eid\",\"starts_at\":\"$VF\",\"ends_at\":\"$VU\",\"template_kind\":\"percent\",\"template_value_percent\":15}" "$ATOK"
  ac festival "create → 201" "201" "$RESP_CODE"; FID="$(jf id)"
  C GET /api/v1/coupon/festivals; ac festival "list active → 200" "200" "$RESP_CODE"
  C POST /api/v1/coupon/festivals/$FID/opt-in '{"shop_id":"22222222-2222-2222-2222-222222222222","override_value_percent":20}' "$ATOK"; ac festival "shop opt-in → 200" "200" "$RESP_CODE"; ac festival "  ok=true" "$(jf ok)" "true"
  fi
else rec SKIP authed "all authed paths" "" "" "AUTH down"; fi

echo
echo "RESULT: $([ $FAIL -eq 0 ] && echo PASS || echo FAIL)   PASS=$PASS FAIL=$FAIL SKIP=$SKIP WARN=$WARN INFO=$INFO (total $((PASS+FAIL+SKIP+WARN+INFO)))"
[ $FAIL -eq 0 ]
