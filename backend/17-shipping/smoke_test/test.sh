#!/usr/bin/env bash
# 17-shipping contract + business smoke. exit 0 ⇔ zero FAILs.
#   SHIP_URL (default http://127.0.0.1:10017) AUTH_URL (10001) SUPPORT_URL (10099) GRPC_EXT (20017)
set -uo pipefail
SHIP_URL=${SHIP_URL:-http://127.0.0.1:10017}
AUTH_URL=${AUTH_URL:-http://127.0.0.1:10001}
SUPPORT_URL=${SUPPORT_URL:-http://127.0.0.1:10099}
GRPC_EXT=${GRPC_EXT:-20017}
WEBHOOK_SECRET=${SHIPPING_WEBHOOK_SECRET:-$(grep -E '^SHIPPING_WEBHOOK_SECRET=' "$HOME/17-shipping/env/.env.dev" 2>/dev/null | cut -d= -f2-)}
WEBHOOK_SECRET=${WEBHOOK_SECRET:-dokandar_shipping_webhook_dev}
PASS=0; FAIL=0
ok(){ echo "[PASS] $*"; PASS=$((PASS+1)); }
no(){ echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
code(){ curl -s -o /dev/null -w "%{http_code}" --max-time 8 "$@"; }

echo "===== 1. Ops contract ====="
[ "$(code $SHIP_URL/ready)" = "200" ] && ok "/ready 200" || no "/ready"
curl -s $SHIP_URL/ready | python3 -c 'import sys,json;d=json.load(sys.stdin);assert d["status"]=="ready";assert d["identity"]["service_name"]=="17-shipping";assert [x["name"] for x in d["dependencies"]]==["postgres"]' 2>/dev/null && ok "/ready postgres-only + identity" || no "/ready body"
curl -s $SHIP_URL/health | python3 -c 'import sys,json;d=json.load(sys.stdin);c=d["checks"];assert all(k in c for k in ["postgres","neo4j","kafka","mongo_logs","apm"]);assert "logs_sink_es" in d["observability"]' 2>/dev/null && ok "/health all deps + observability" || no "/health"
curl -s $SHIP_URL/metrics | grep -q "shipping_outbox_pending" && ok "/metrics has shipping_outbox_pending (mandatory)" || no "/metrics outbox gauge"
curl -s $SHIP_URL/metrics | grep -q "http_request" || curl -s -o /dev/null $SHIP_URL/openapi.json
curl -s $SHIP_URL/metrics | grep -q "http_request" && ok "/metrics RED" || no "/metrics RED"
curl -s $SHIP_URL/openapi.json | python3 -c 'import sys,json;d=json.load(sys.stdin);assert d["info"]["title"]=="DOKANDAR Shipping Service";assert "/api/v1/shipping/quote" in d["paths"]' 2>/dev/null && ok "/openapi.json title + routes" || no "/openapi.json"
[ "$(code $SHIP_URL/docs)" = "200" ] && ok "/docs 200" || no "/docs"
C=$(code $SHIP_URL/nope); CT=$(curl -s -o /dev/null -w "%{content_type}" $SHIP_URL/nope); SZ=$(curl -s -o /dev/null -w "%{size_download}" $SHIP_URL/nope)
[ "$C" = "404" ] && [ -z "$CT" ] && [ "$SZ" = "0" ] && ok "bare-404 (no CT, 0 bytes)" || no "bare-404 c=$C ct=$CT sz=$SZ"
{ [ "$(code $SHIP_URL/data)" = "200" ] || [ "$(code $SHIP_URL/data)" = "404" ]; } && ok "/data 200|404" || no "/data"

echo "===== 2. Mint a customer token ====="
PH=$(printf "017%08d" $(( (RANDOM*RANDOM) % 100000000 )))
curl -s -m8 -X POST $AUTH_URL/api/v1/auth/signup/request -H 'content-type: application/json' -d "{\"phone\":\"$PH\"}" >/dev/null; sleep 1.5
OTP=$(curl -s -m8 "$SUPPORT_URL/otp/latest?phone=$PH&purpose=signup" | python3 -c "import sys,json;print(json.load(sys.stdin).get('code',''))" 2>/dev/null)
TOK=$(curl -s -m8 -X POST $AUTH_URL/api/v1/auth/signup/verify -H 'content-type: application/json' -d "{\"phone\":\"$PH\",\"name\":\"Ship\",\"role\":\"customer\",\"code\":\"$OTP\"}" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
[ -n "$TOK" ] && ok "minted customer token" || no "mint failed"

echo "===== 3. Business REST + auth gates ====="
[ "$(code "$SHIP_URL/api/v1/shipping/quote?tier=city")" = "401" ] && ok "quote no-token → 401" || no "quote no-token"
[ "$(code -H "authorization: Bearer $TOK" "$SHIP_URL/api/v1/shipping/quote?tier=district&weight=1500&upazila=savar")" = "200" ] && ok "quote with token → 200" || no "quote with token"
SUB=$(python3 -c "import uuid;print(uuid.uuid4())")
[ "$(code -X POST -H "authorization: Bearer $TOK" -H "content-type: application/json" -d "{\"sub_order_id\":\"$SUB\",\"address_tier\":\"city\"}" "$SHIP_URL/api/v1/shipping/shipments")" = "400" ] && ok "shipment create no Idempotency-Key → 400" || no "missing idem key"
IK="SMK-$SUB"
[ "$(code -X POST -H "authorization: Bearer $TOK" -H "Idempotency-Key: $IK" -H "content-type: application/json" -d "{\"sub_order_id\":\"$SUB\",\"address_tier\":\"city\"}" "$SHIP_URL/api/v1/shipping/shipments")" = "201" ] && ok "shipment create → 201" || no "create 201"
[ "$(code -X POST -H "authorization: Bearer $TOK" -H "Idempotency-Key: $IK" -H "content-type: application/json" -d "{\"sub_order_id\":\"$SUB\",\"address_tier\":\"city\"}" "$SHIP_URL/api/v1/shipping/shipments")" = "409" ] && ok "shipment dup idem → 409 already_booked" || no "dup 409"
[ "$(code -H "authorization: Bearer $TOK" "$SHIP_URL/api/v1/shipping/shipments/by-order/$SUB")" = "200" ] && ok "GET by-order → 200" || no "by-order"
[ "$(code -X POST -H "X-Courier-Signature: $WEBHOOK_SECRET" -H "content-type: application/json" -d "{\"sub_order_id\":\"$SUB\",\"status\":\"delivered\"}" "$SHIP_URL/api/v1/shipping/webhooks/pathao")" = "200" ] && ok "webhook signed → 200" || no "webhook signed"
[ "$(code -X POST -H "X-Courier-Signature: wrong" -d '{}' "$SHIP_URL/api/v1/shipping/webhooks/pathao")" = "403" ] && ok "webhook bad sig → 403" || no "webhook bad sig"
[ "$(code -H "authorization: Bearer $TOK" "$SHIP_URL/api/v1/shipping/admin/agents")" = "200" ] && ok "agents index (token) → 200" || no "agents index"
[ "$(code -X POST -H "authorization: Bearer $TOK" -d '{}' "$SHIP_URL/api/v1/shipping/admin/agents")" = "403" ] && ok "agents create as customer → 403 (admin gate)" || no "agents create gate"

echo "===== 4. gRPC QuoteDelivery (reachability @ $GRPC_EXT) ====="
(timeout 3 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/$GRPC_EXT") 2>/dev/null && ok "gRPC port $GRPC_EXT open" || no "gRPC port"

echo "================================================================"
echo "  RESULT: $([ $FAIL = 0 ] && echo PASS || echo FAIL)   PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[ "$FAIL" = "0" ]
