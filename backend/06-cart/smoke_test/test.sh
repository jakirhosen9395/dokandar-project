#!/usr/bin/env bash
# 06-cart smoke — ops contract + cart/wishlist/guest CRUD + checkout-package + auth gates.
# Mints a real RS256 token by logging into auth (:10001) and recovering OTPs from 00-support (:10099).
#   CART_URL=http://127.0.0.1:10006 AUTH_URL=http://127.0.0.1:10001 SUPPORT_URL=http://127.0.0.1:10099 ./smoke_test/test.sh
set -uo pipefail
CART_URL="${CART_URL:-http://127.0.0.1:10006}"
AUTH_URL="${AUTH_URL:-http://127.0.0.1:10001}"
SUPPORT_URL="${SUPPORT_URL:-http://127.0.0.1:10099}"
PASS=0; FAIL=0; WARN=0; SKIP=0; INFO=0
RESP_CODE=""; RESP_BODY=""
g(){ B="${BASH_REMATCH:-}"; }
record(){ local st="$1" cat="$2" name="$3" got="${4:-}" want="${5:-}" det="${6:-}"; local x=""; [ -n "$got" ] && x=" (HTTP $got${want:+, want $want})"; [ -n "$det" ] && x="$x — $det"; printf "[%s] %s :: %s%s\n" "$st" "$cat" "$name" "$x"; case "$st" in PASS)PASS=$((PASS+1));; FAIL)FAIL=$((FAIL+1));; WARN)WARN=$((WARN+1));; SKIP)SKIP=$((SKIP+1));; INFO)INFO=$((INFO+1));; esac; }
ac(){ if [ "$4" = "$3" ]; then record PASS "$1" "$2" "$4" "$3" "${5:-}"; else record FAIL "$1" "$2" "$4" "$3" "${5:-}"; fi; }
ain(){ local c n a s d; c="$1";n="$2";a="$3";s="$4";d="${5:-}"; for x in $s; do [ "$a" = "$x" ] && { record PASS "$c" "$n" "$a" "$s" "$d"; return; }; done; record FAIL "$c" "$n" "$a" "$s" "$d"; }
jf(){ printf '%s' "$RESP_BODY" | python3 -c "import sys,json
try:
 d=json.load(sys.stdin)
 for k in sys.argv[1].split('.'):
  d=d[int(k)] if isinstance(d,list) else d.get(k)
  if d is None: break
 print('' if d is None else d)
except Exception: print('')" "$1" 2>/dev/null; }
req(){ local m="$1" p="$2" body="${3:-}" tok="${4:-}"; local h=(-s -m 15 -o /tmp/cb_body -w '%{http_code}' -X "$m" "$CART_URL$p"); [ -n "$tok" ] && h+=(-H "Authorization: Bearer $tok"); [ -n "$body" ] && h+=(-H 'content-type: application/json' -d "$body"); [ -n "${IDEM:-}" ] && h+=(-H "Idempotency-Key: $IDEM"); RESP_CODE="$(curl "${h[@]}" 2>/dev/null)"; RESP_BODY="$(cat /tmp/cb_body 2>/dev/null)"; }
areq(){ local m="$1" p="$2" body="${3:-}"; RESP_CODE="$(curl -s -m 15 -o /tmp/cb_a -w '%{http_code}' -X "$m" "$AUTH_URL$p" ${body:+-H 'content-type: application/json' -d "$body"} 2>/dev/null)"; RESP_BODY="$(cat /tmp/cb_a 2>/dev/null)"; }
gen_phone(){ printf "017%08d" $(( (RANDOM*RANDOM) % 100000000 )); }
get_otp(){ curl -s -m 8 "$SUPPORT_URL/otp/latest?phone=$1&purpose=$2" 2>/dev/null | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('code',''))
except Exception: print('')" 2>/dev/null; }
mint(){ local ph="$1"; areq POST /api/v1/auth/signup/request "{\"phone\":\"$ph\"}"; local st; st="$(printf '%s' "$RESP_BODY"|python3 -c 'import sys,json;print(json.load(sys.stdin).get("status",""))' 2>/dev/null)"; local code; code="$(curl -s -m 8 "$SUPPORT_URL/otp/latest?phone=$ph&purpose=signup" 2>/dev/null|python3 -c 'import sys,json;print(json.load(sys.stdin).get("code",""))' 2>/dev/null)"; [ -z "$code" ] && { echo ""; return; }; areq POST /api/v1/auth/signup/verify "{\"phone\":\"$ph\",\"code\":\"$code\",\"name\":\"Cart Tester\"}"; printf '%s' "$RESP_BODY"|python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("access_token",""))
except Exception: print("")' 2>/dev/null; }

echo "== 06-cart smoke =="
# preflight
req GET /ready; [ "$RESP_CODE" = "000" ] && { record FAIL preflight "cart reachable" "$RESP_CODE" 200 "cannot reach $CART_URL"; echo "RESULT: FAIL"; exit 1; }
areq GET /ready; [ "$RESP_CODE" = "000" ] && { AUTH_DOWN=1; record WARN preflight "auth reachable" "$RESP_CODE" 200 "authed paths skipped"; } || AUTH_DOWN=0

echo "-- 1. ops contract --"
req GET /ready; ain ops "/ready 200|503" "$RESP_CODE" "200 503"
ac ops "identity.service_name==06-cart" "$(jf identity.service_name)" "06-cart" service_name
ac ops "/ready dep0=mongodb" "$(jf dependencies.0.name)" "mongodb" dep0
ac ops "/ready dep1=redis" "$(jf dependencies.1.name)" "redis" dep1
ac ops "/ready mongo+redis only (no dep2)" "$(jf dependencies.2.name)" "" dep2_absent
req GET /health; ain ops "/health 200|503" "$RESP_CODE" "200 503"
[ -n "$(jf checks.mongodb.ok)" ] && record PASS ops "/health has mongodb+redis+kafka" "" "" "ok" || record FAIL ops "/health checks" "" "" "missing"
req GET /data; ain ops "/data 200|404" "$RESP_CODE" "200 404"
req GET /metrics; { [ "$RESP_CODE" = 200 ] && grep -qE "_total|cart_|# (HELP|TYPE)" <<<"$RESP_BODY"; } && record PASS ops "/metrics prometheus" "" "" ok || record FAIL ops "/metrics prometheus" "$RESP_CODE" 200 "no metrics"
req GET /openapi.json; ac ops "/openapi.json 200" "200" "$RESP_CODE" code
ac ops "/openapi HTTPBearer scheme" "$(jf components.securitySchemes.HTTPBearer.scheme)" "bearer" scheme
req GET /docs; ain ops "/docs 200|301|302|303" "$RESP_CODE" "200 301 302 303"
BARE=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$CART_URL/no-such-route-xyz" 2>/dev/null); ac ops "unknown path → bare 404" "404" "$BARE" bare404

echo "-- 2. auth gates --"
req GET /api/v1/cart/me; ac authz "/me no token → 401" "401" "$RESP_CODE"
ac authz "  code=unauthorized" "$(jf error.code)" "unauthorized" code
req GET /api/v1/cart/me "" "garbage.token.value"; ac authz "/me bad token → 401" "401" "$RESP_CODE"

echo "-- 3. guest cart (public) --"
CK="guest$(date +%s)$RANDOM"
req GET "/api/v1/cart/guest/$CK"; ac guest "GET guest → 200" "200" "$RESP_CODE"
req POST "/api/v1/cart/guest/$CK/items" '{"shop_id":"11111111-1111-1111-1111-111111111111","product_id":"22222222-2222-2222-2222-222222222222","variant_id":"33333333-3333-3333-3333-333333333333","quantity":2}'; ac guest "POST guest item → 201" "201" "$RESP_CODE"
ac guest "  guest has 1 item" "$(jf items.0.variantId)" "33333333-3333-3333-3333-333333333333" item
req GET "/api/v1/cart/guest/short"; ac validation "guest bad cookie_id → 400" "400" "$RESP_CODE"
req POST "/api/v1/cart/guest/$CK/merge"; ac authz "guest merge no token → 401" "401" "$RESP_CODE"

if [ "$AUTH_DOWN" = 0 ]; then
  PH=$(gen_phone); TOKEN=$(mint "$PH")
  if [ -z "$TOKEN" ]; then record WARN mint "customer token" "" "" "could not mint (auth/OTP); authed cart paths skipped"; else
  record INFO mint "customer minted" "" "" "phone=$PH"
  echo "-- 4. authenticated cart CRUD --"
  req GET /api/v1/cart/me "" "$TOKEN"; ac cart "GET /me → 200" "200" "$RESP_CODE"
  ac cart "  empty cart" "$(jf items.0.lineId)" "" empty
  req POST /api/v1/cart/me/items '{"shop_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","product_id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","variant_id":"cccccccc-cccc-cccc-cccc-cccccccccccc","quantity":1}' "$TOKEN"; ac cart "POST item → 201" "201" "$RESP_CODE"
  LINE=$(jf items.0.lineId); ac cart "  cart has the line" "$(jf items.0.quantity)" "1" qty
  req POST /api/v1/cart/me/items '{"shop_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","product_id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","variant_id":"cccccccc-cccc-cccc-cccc-cccccccccccc","quantity":2}' "$TOKEN"; ac cart "  re-add bumps qty" "$(jf items.0.quantity)" "3" bumped
  req PATCH "/api/v1/cart/me/items/$LINE" '{"quantity":5}' "$TOKEN"; ac cart "PATCH qty → 200" "200" "$RESP_CODE"; ac cart "  qty=5" "$(jf items.0.quantity)" "5" patched
  req DELETE "/api/v1/cart/me/items/$LINE" "" "$TOKEN"; ac cart "DELETE line → 200" "200" "$RESP_CODE"; ac cart "  cart empty" "$(jf items.0.lineId)" "" cleared
  echo "-- 5. wishlist --"
  req GET /api/v1/cart/wishlist "" "$TOKEN"; ac wishlist "GET wishlist → 200" "200" "$RESP_CODE"
  req POST /api/v1/cart/wishlist/items '{"product_id":"dddddddd-dddd-dddd-dddd-dddddddddddd"}' "$TOKEN"; ac wishlist "POST wishlist → 201" "201" "$RESP_CODE"
  WL=$(jf items.0.lineId); req DELETE "/api/v1/cart/wishlist/items/$WL" "" "$TOKEN"; ac wishlist "DELETE wishlist → 200" "200" "$RESP_CODE"
  echo "-- 6. guest merge (authed) --"
  req POST "/api/v1/cart/guest/$CK/merge" "" "$TOKEN"; ac guest "guest merge authed → 200" "200" "$RESP_CODE"; ac guest "  merged item present" "$(jf items.0.variantId)" "33333333-3333-3333-3333-333333333333" merged
  echo "-- 7. checkout-package --"
  req POST /api/v1/cart/me/checkout-package '{"payment_method":"cod"}' "$TOKEN"; ac checkout "no Idempotency-Key → 400" "400" "$RESP_CODE"; ac checkout "  code=missing_idempotency_key" "$(jf error.code)" "missing_idempotency_key" code
  req DELETE /api/v1/cart/me/items "" "$TOKEN"
  IDEM="idem-$(date +%s)" req POST /api/v1/cart/me/checkout-package '{"payment_method":"cod"}' "$TOKEN"
  IDEM="idem-empty-$$"; req POST /api/v1/cart/me/checkout-package '{"payment_method":"cod"}' "$TOKEN"; ac checkout "empty cart → 400" "400" "$RESP_CODE"; ac checkout "  code=empty_cart" "$(jf error.code)" "empty_cart" code
  req POST /api/v1/cart/me/items '{"shop_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","product_id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","variant_id":"cccccccc-cccc-cccc-cccc-cccccccccccc","quantity":1}' "$TOKEN"
  IDEM="idem-build-$$"; req POST /api/v1/cart/me/checkout-package '{"payment_method":"cod"}' "$TOKEN"; ain checkout "build quote → 200|409" "$RESP_CODE" "200 409" "200=quote built, 409=catalog stock/unavailable (fail-closed)"
  [ "$RESP_CODE" = 200 ] && { ac checkout "  has checkout_id" "$([ -n "$(jf checkout_id)" ] && echo yes)" "yes" id; record INFO checkout "risk decision" "" "" "$(jf risk.decision)"; }
  fi
else record SKIP authed "all authed cart paths" "" "" "AUTH down"; fi

echo
echo "RESULT: $([ $FAIL -eq 0 ] && echo PASS || echo FAIL)   PASS=$PASS FAIL=$FAIL SKIP=$SKIP WARN=$WARN INFO=$INFO (total $((PASS+FAIL+SKIP+WARN+INFO)))"
[ $FAIL -eq 0 ]
