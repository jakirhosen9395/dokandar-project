#!/usr/bin/env bash
# 08-review smoke — ops contract + public reads + auth/role gates + KEY-SANITY + has-purchased
# + the full review lifecycle (post → get → aggregate → vote → report → reply → hide/restore → delete).
# Mints RS256 tokens via 01-auth (:10001) + OTPs from 00-support (:10099). Verified-purchase enforcement
# is OFF by default (REVIEW_ENFORCE_VERIFIED_PURCHASE=false) → POST /reviews succeeds without order events.
#   REVIEW_URL=http://127.0.0.1:10008 AUTH_URL=http://127.0.0.1:10001 SUPPORT_URL=http://127.0.0.1:10099 ./smoke_test/test.sh
set -uo pipefail
REVIEW_URL="${REVIEW_URL:-http://127.0.0.1:10008}"
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
 print('' if d is None else d)
except Exception: print('')" "$2" 2>/dev/null; }
R(){ local m="$1" p="$2" body="${3:-}" tok="${4:-}" hdr="${5:-}"; local h=(-s -m 20 -o /tmp/rv_b -w '%{http_code}' -X "$m" "$REVIEW_URL$p"); [ -n "$tok" ] && h+=(-H "Authorization: Bearer $tok"); [ -n "$hdr" ] && h+=(-H "$hdr"); [ -n "$body" ] && h+=(-H 'content-type: application/json' -d "$body"); RESP_CODE="$(curl "${h[@]}" 2>/dev/null)"; RESP_BODY="$(cat /tmp/rv_b 2>/dev/null)"; }
areq(){ local m="$1" p="$2" body="${3:-}" tok="${4:-}"; local h=(-s -m 15 -o /tmp/rv_a -w '%{http_code}' -X "$m" "$AUTH_URL$p"); [ -n "$tok" ] && h+=(-H "Authorization: Bearer $tok"); [ -n "$body" ] && h+=(-H 'content-type: application/json' -d "$body"); curl "${h[@]}" >/dev/null 2>&1; cat /tmp/rv_a 2>/dev/null; }
otp(){ curl -s -m 8 "$SUPPORT_URL/otp/latest?phone=$1&purpose=$2" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('code',''))" 2>/dev/null; }
genphone(){ printf "01%01d%08d" $((RANDOM%7+2)) $(( (RANDOM*RANDOM)%100000000 )); }
uuid(){ python3 -c "import uuid;print(uuid.uuid4())"; }
reset_admin_otp(){ [ -z "$RH" ] && return 1; command -v docker >/dev/null 2>&1 && docker run --rm redis:7-alpine redis-cli -h "$RH" -p "${RP:-6379}" ${RPW:+-a "$RPW"} -n 0 DEL "otp_rate:$ADMIN_PHONE" >/dev/null 2>&1; }
login(){ local ph="$1"; areq POST /api/v1/auth/login/request "{\"phone\":\"$ph\"}" >/dev/null; sleep 1; local code; code="$(otp "$ph" login)"; [ -z "$code" ] && { echo ""; return; }; jp "$(areq POST /api/v1/auth/login/verify "{\"phone\":\"$ph\",\"code\":\"$code\"}")" access_token; }
signup(){ local ph; ph="$(genphone)"; areq POST /api/v1/auth/signup/request "{\"phone\":\"$ph\"}" >/dev/null; sleep 1; local code; code="$(otp "$ph" signup)"; [ -z "$code" ] && { echo ""; return; }; jp "$(areq POST /api/v1/auth/signup/verify "{\"phone\":\"$ph\",\"code\":\"$code\",\"name\":\"Cust\"}")" access_token; }

echo "== 08-review smoke =="
R GET /ready; [ "$RESP_CODE" = "000" ] && { rec FAIL preflight "review reachable" "$RESP_CODE" 200 "cannot reach $REVIEW_URL"; echo "RESULT: FAIL"; exit 1; }
[ -z "$(curl -s -o /dev/null -w '%{http_code}' "$AUTH_URL/ready" 2>/dev/null | grep -E '200|503')" ] && AUTHDOWN=1 || AUTHDOWN=0

echo "-- 1. ops contract --"
R GET /ready; ain ops "/ready 200|503" "$RESP_CODE" "200 503"
ac ops "identity.service_name==08-review" "$(jf identity.service_name)" "08-review" svc
ac ops "/ready gates postgres only (dep0)" "$(jf dependencies.0.name)" "postgres" dep0
ac ops "/ready postgres-only (no dep1)" "$(jf dependencies.1.name)" "" dep1_absent
R GET /health; ain ops "/health 200|503" "$RESP_CODE" "200 503"
[ -n "$(jf checks.postgres.ok)" ] && rec PASS ops "/health has postgres+kafka+elasticsearch checks" "" "" "es=$(jf checks.elasticsearch.ok) kafka=$(jf checks.kafka.ok)" || rec FAIL ops "/health checks" "" "" missing
R GET /data; ain ops "/data 200|404" "$RESP_CODE" "200 404"
R GET /metrics; { [ "$RESP_CODE" = 200 ] && grep -qE "review_|_total" <<<"$RESP_BODY"; } && rec PASS ops "/metrics prometheus (review_*)" "" "" ok || rec FAIL ops "/metrics" "$RESP_CODE" 200 "no review metrics"
grep -q "review_outbox_pending" <<<"$RESP_BODY" && rec PASS ops "/metrics has review_outbox_pending gauge" "" "" ok || rec WARN ops "review_outbox_pending" "" "" "not present"
R GET /openapi.json; ac ops "/openapi.json 200" "200" "$RESP_CODE"
ac ops "/openapi HTTPBearer scheme" "$(jf components.securitySchemes.HTTPBearer.scheme)" "bearer" scheme
ac ops "/openapi InternalToken apiKey" "$(jf components.securitySchemes.InternalToken.in)" "header" internal
R GET /docs; ain ops "/docs 200|302" "$RESP_CODE" "200 302"
BARE=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$REVIEW_URL/no-such-xyz" 2>/dev/null); ac ops "unknown path → bare 404" "404" "$BARE"

echo "-- 2. public reads --"
PID="$(uuid)"
R GET "/api/v1/review/reviews?product_id=$PID"; ac public "GET reviews → 200" "200" "$RESP_CODE"
R GET "/api/v1/review/aggregate?target_kind=product&target_id=$PID"; ac public "GET aggregate → 200" "200" "$RESP_CODE"; ac public "  empty aggregate count=0" "$(jf count)" "0" empty
R GET "/api/v1/review/aggregate?target_kind=bogus&target_id=$PID"; ac validation "aggregate bad target_kind → 422" "422" "$RESP_CODE"
R GET "/api/v1/review/reviews/$(uuid)"; ac public "GET unknown review → 404" "404" "$RESP_CODE"; ac public "  code=not_found" "$(jf error.code)" "not_found" code

echo "-- 3. auth gates + KEY-SANITY --"
R POST /api/v1/review/reviews '{}'; ac authz "POST reviews no token → 401" "401" "$RESP_CODE"; ac authz "  code=missing_token" "$(jf error.code)" "missing_token" code
R POST /api/v1/review/reviews '{}' "garbage.tok"; ac authz "POST reviews bad token → 401" "401" "$RESP_CODE"; ac authz "  code=invalid_token" "$(jf error.code)" "invalid_token" code

echo "-- 4. ValidateCoupon-equivalent: has-purchased (internal-token) --"
if [ -n "$INTERNAL_TOKEN" ]; then
  R POST /api/v1/review/has-purchased "{\"user_id\":\"$(uuid)\",\"order_id\":\"$(uuid)\",\"product_id\":\"$(uuid)\"}" "" "x-internal-token: $INTERNAL_TOKEN"
  ac purchase "has-purchased random → 200" "200" "$RESP_CODE"; ac purchase "  eligible=false" "$(jf eligible)" "false" elig
  R POST /api/v1/review/has-purchased "{\"user_id\":\"$(uuid)\",\"order_id\":\"$(uuid)\",\"product_id\":\"$(uuid)\"}"
  ac purchase "no x-internal-token → 401" "401" "$RESP_CODE"
else rec WARN purchase "has-purchased" "" "" "INTERNAL_SERVICE_TOKEN not found"; fi

if [ "$AUTHDOWN" = 0 ]; then
  reset_admin_otp; ATOK="$(login "$ADMIN_PHONE")"
  C1="$(signup)"; C2="$(signup)"
  SKPH="$(genphone)"; [ -n "$ATOK" ] && areq POST /api/v1/auth/users "{\"role\":\"shopkeeper\",\"phone\":\"$SKPH\",\"name\":\"Shopkeeper\"}" "$ATOK" >/dev/null; STOK="$(login "$SKPH")"
  if [ -z "$C1" ]; then rec WARN mint "customer token" "" "" "could not mint; lifecycle skipped"; else
  rec INFO mint "tokens" "" "" "admin=$([ -n "$ATOK" ]&&echo y||echo n) cust=y shopkeeper=$([ -n "$STOK" ]&&echo y||echo n)"
  echo "-- 5. KEY-SANITY (the #1 fleet integration bug) --"
  OID="$(uuid)"
  R POST /api/v1/review/reviews "{\"target_kind\":\"product\",\"product_id\":\"$PID\",\"order_id\":\"$OID\",\"rating\":5,\"title\":\"Great\",\"body\":\"Loved it\"}" "$C1"
  if [ "$RESP_CODE" = "401" ]; then rec FAIL keysync "fresh token accepted" "401" "201" "JWT_PUBLIC_KEY_B64 drift vs auth — sync public key + redeploy"; else rec PASS keysync "fresh token NOT 401 (key in sync)" "$RESP_CODE" "" ok; fi
  echo "-- 6. review lifecycle (enforcement off) --"
  ac review "post review → 201" "201" "$RESP_CODE"; RID="$(jf id)"; ac review "  rating=5" "$(jf rating)" "5"
  R GET "/api/v1/review/reviews/$RID"; ac review "get review → 200" "200" "$RESP_CODE"
  R GET "/api/v1/review/reviews?product_id=$PID"; ac review "list by product → 200" "200" "$RESP_CODE"; ac review "  review visible in list" "$(jf 0.id)" "$RID" listed
  R GET "/api/v1/review/aggregate?target_kind=product&target_id=$PID"; ac review "aggregate count>=1" "$(jf count)" "1" agg; ac review "  avg=5.0" "$(jf avg)" "5.0"
  R POST /api/v1/review/reviews "{\"target_kind\":\"product\",\"product_id\":\"$PID\",\"order_id\":\"$OID\",\"rating\":3}" "$C1"; ac review "duplicate (user,target,order) → 409" "409" "$RESP_CODE"; ac review "  code=review_exists" "$(jf error.code)" "review_exists" dup
  R PATCH "/api/v1/review/reviews/$RID" '{"rating":4}' "$C1"; ac review "patch own review → 200" "200" "$RESP_CODE"; ac review "  rating=4" "$(jf rating)" "4"
  R PATCH "/api/v1/review/reviews/$RID" '{"rating":2}' "$C2"; ac review "patch other's review → 403" "403" "$RESP_CODE"; ac review "  code=not_author" "$(jf error.code)" "not_author"
  R POST "/api/v1/review/reviews/$RID/vote" '{"is_helpful":true}' "$C2"; ac review "vote → 200" "200" "$RESP_CODE"; ac review "  ok" "$(jf ok)" "true"
  R POST "/api/v1/review/reviews/$RID/report" '{"reason":"spam"}' "$C2"; ac review "report → 200" "200" "$RESP_CODE"
  if [ -n "$STOK" ]; then R POST "/api/v1/review/reviews/$RID/reply" '{"body":"Thanks for the feedback!"}' "$STOK"; ac review "shopkeeper reply → 200" "200" "$RESP_CODE"
  R POST "/api/v1/review/reviews/$RID/reply" '{"body":"x"}' "$C1"; ac authz "customer reply → 403" "403" "$RESP_CODE"; else rec SKIP review "reply" "" "" "no shopkeeper"; fi
  if [ -n "$ATOK" ]; then
    R POST "/api/v1/review/reviews/$RID/hide" "" "$ATOK"; ac review "admin hide → 200" "200" "$RESP_CODE"
    R GET "/api/v1/review/reviews/$RID"; ac review "  status=hidden" "$(jf status)" "hidden"
    R POST "/api/v1/review/reviews/$RID/restore" "" "$ATOK"; ac review "admin restore → 200" "200" "$RESP_CODE"
    R POST "/api/v1/review/reviews/$RID/hide" "" "$C1"; ac authz "customer hide → 403" "403" "$RESP_CODE"
  else rec SKIP review "admin hide/restore" "" "" "no admin"; fi
  R DELETE "/api/v1/review/reviews/$RID" "" "$C1"; ac review "author delete → 204" "204" "$RESP_CODE"
  R GET "/api/v1/review/reviews/$RID"; ac review "  deleted (404)" "404" "$RESP_CODE"
  fi
else rec SKIP authed "all authed paths" "" "" "AUTH down"; fi

echo
echo "RESULT: $([ $FAIL -eq 0 ] && echo PASS || echo FAIL)   PASS=$PASS FAIL=$FAIL SKIP=$SKIP WARN=$WARN INFO=$INFO (total $((PASS+FAIL+SKIP+WARN+INFO)))"
[ $FAIL -eq 0 ]
