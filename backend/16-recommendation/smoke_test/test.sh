#!/usr/bin/env bash
# 16-recommendation contract + business smoke. exit 0 ⇔ zero FAILs.
# Mints a real RS256 customer token via 01-auth + the 00-support OTP read-back.
#   RECO_URL (default http://127.0.0.1:10016) AUTH_URL (10001) SUPPORT_URL (10099) GRPC_EXT (20016)
set -uo pipefail
RECO_URL=${RECO_URL:-http://127.0.0.1:10016}
AUTH_URL=${AUTH_URL:-http://127.0.0.1:10001}
SUPPORT_URL=${SUPPORT_URL:-http://127.0.0.1:10099}
GRPC_EXT=${GRPC_EXT:-20016}
PASS=0; FAIL=0
ok(){ echo "[PASS] $*"; PASS=$((PASS+1)); }
no(){ echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
info(){ echo "[INFO] $*"; }
code(){ curl -s -o /dev/null -w "%{http_code}" --max-time 8 "$@"; }

echo "===== 1. Ops contract ====="
RC=$(code "$RECO_URL/ready"); [ "$RC" = "200" ] && ok "/ready → 200" || no "/ready → $RC"
curl -s --max-time 8 "$RECO_URL/ready" | python3 -c 'import sys,json;d=json.load(sys.stdin);assert d["status"]=="ready";assert d["identity"]["service_name"]=="16-recommendation";assert d["identity"]["code_version"]=="16-recommendation";assert [x["name"] for x in d["dependencies"]]==["postgres"]' 2>/dev/null \
  && ok "/ready identity + postgres-only gate" || no "/ready body/identity/gate wrong"
curl -s --max-time 8 "$RECO_URL/health" | python3 -c 'import sys,json;d=json.load(sys.stdin);c=d["checks"];assert all(k in c for k in ["postgres","qdrant","redis","kafka","mongo_logs","apm"]);assert d["status"]=="healthy";assert "logs_sink_es" in d["observability"]' 2>/dev/null \
  && ok "/health all deps + observability block" || no "/health missing deps/observability"
RC=$(code "$RECO_URL/metrics"); [ "$RC" = "200" ] && ok "/metrics → 200" || no "/metrics → $RC"
curl -s -o /dev/null --max-time 8 "$RECO_URL/openapi.json"   # warm up: record ≥1 non-excluded request for RED
curl -s --max-time 8 "$RECO_URL/metrics" | grep -q "http_request" && ok "/metrics has RED" || no "/metrics no RED"
RC=$(code "$RECO_URL/openapi.json"); [ "$RC" = "200" ] && ok "/openapi.json → 200" || no "/openapi.json → $RC"
curl -s --max-time 8 "$RECO_URL/openapi.json" | python3 -c 'import sys,json;d=json.load(sys.stdin);assert d["info"]["title"]=="DOKANDAR Recommendation Service";p=d["paths"];assert "/api/v1/recommendation/feed/me" in p and "/api/v1/recommendation/similar/{product_id}" in p' 2>/dev/null \
  && ok "/openapi.json title + documents routes" || no "/openapi.json title/routes"
RC=$(code "$RECO_URL/docs"); [ "$RC" = "200" ] && ok "/docs → 200" || no "/docs → $RC"
# bare-404
BODY=$(curl -s --max-time 8 "$RECO_URL/nope-xyz"); CL=$(curl -s -o /dev/null -w "%{size_download}" --max-time 8 "$RECO_URL/nope-xyz")
RC=$(code "$RECO_URL/nope-xyz"); [ "$RC" = "404" ] && [ "$CL" = "0" ] && ok "bare-404 (empty body)" || no "bare-404 → $RC size=$CL"
# /data
RC=$(code "$RECO_URL/data"); { [ "$RC" = "200" ] || [ "$RC" = "404" ]; } && ok "/data → $RC (200|404 ok)" || no "/data → $RC"

echo "===== 2. Mint a customer token ====="
PH=$(printf "017%08d" $(( (RANDOM*RANDOM) % 100000000 )))
curl -s -m 8 -X POST "$AUTH_URL/api/v1/auth/signup/request" -H 'content-type: application/json' -d "{\"phone\":\"$PH\"}" >/dev/null
OTP=""; sleep 1.5
for _ in $(seq 1 12); do
  OTP=$(curl -s -m 8 "$SUPPORT_URL/otp/latest?phone=$PH&purpose=signup" | python3 -c "import sys,json;print(json.load(sys.stdin).get('code',''))" 2>/dev/null)
  [ -n "$OTP" ] && break; sleep 1
done
BODY="{\"phone\":\"$PH\",\"name\":\"Reco Tester\",\"role\":\"customer\""; [ -n "$OTP" ] && BODY="$BODY,\"code\":\"$OTP\""; BODY="$BODY}"
TOKEN=$(curl -s -m 8 -X POST "$AUTH_URL/api/v1/auth/signup/verify" -H 'content-type: application/json' -d "$BODY" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
[ -n "$TOKEN" ] && ok "minted customer token (phone=$PH)" || no "mint failed"

echo "===== 3. REST routes + auth gates ====="
RC=$(code "$RECO_URL/api/v1/recommendation/feed/me"); [ "$RC" = "401" ] && ok "feed/me no-token → 401" || no "feed/me no-token → $RC"
if [ -n "$TOKEN" ]; then
  RC=$(code -H "authorization: Bearer $TOKEN" "$RECO_URL/api/v1/recommendation/feed/me?size=10")
  [ "$RC" = "200" ] && ok "feed/me with token → 200 (RS256 key aligned)" || no "feed/me with token → $RC"
  curl -s --max-time 8 -H "authorization: Bearer $TOKEN" "$RECO_URL/api/v1/recommendation/feed/me?size=10" | python3 -c 'import sys,json;d=json.load(sys.stdin);assert "items" in d and "source" in d' 2>/dev/null \
    && ok "feed/me returns a Feed{source,items}" || no "feed/me body shape"
  RC=$(code -X POST -H "authorization: Bearer $TOKEN" "$RECO_URL/api/v1/recommendation/admin/retrain")
  [ "$RC" = "403" ] && ok "admin/retrain as customer → 403 (admin gate)" || no "admin/retrain customer → $RC (want 403)"
fi
PID="00000000-0000-0000-0000-000000000001"
RC=$(code "$RECO_URL/api/v1/recommendation/similar/$PID"); [ "$RC" = "200" ] && ok "similar (public) → 200" || no "similar → $RC"
RC=$(code "$RECO_URL/api/v1/recommendation/cross-sell?product_id=$PID"); [ "$RC" = "200" ] && ok "cross-sell (public) → 200" || no "cross-sell → $RC"
RC=$(code "$RECO_URL/api/v1/recommendation/cross-sell"); [ "$RC" = "422" ] && ok "cross-sell missing product_id → 422" || no "cross-sell no-arg → $RC (want 422)"

echo "===== 4. gRPC feed server (reachability @ $GRPC_EXT) ====="
if (timeout 3 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/$GRPC_EXT") 2>/dev/null; then
  ok "gRPC port $GRPC_EXT open (feed server listening)"
else
  no "gRPC port $GRPC_EXT not reachable"
fi

echo "================================================================"
echo "  RESULT: $([ $FAIL = 0 ] && echo PASS || echo FAIL)   PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[ "$FAIL" = "0" ]
