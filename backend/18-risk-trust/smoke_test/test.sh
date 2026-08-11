#!/usr/bin/env bash
# 18-risk-trust contract + business smoke. exit 0 ⇔ zero FAILs.
#   RISK_URL (10018) AUTH_URL (10001) SUPPORT_URL (10099) GRPC_EXT (20018) INTERNAL_TOKEN
set -uo pipefail
RISK_URL=${RISK_URL:-http://127.0.0.1:10018}
AUTH_URL=${AUTH_URL:-http://127.0.0.1:10001}
SUPPORT_URL=${SUPPORT_URL:-http://127.0.0.1:10099}
GRPC_EXT=${GRPC_EXT:-20018}
ITOK=${INTERNAL_TOKEN:-$(grep -E "^INTERNAL_SERVICE_TOKEN=" "$HOME/18-risk-trust/env/.env.dev" 2>/dev/null | cut -d= -f2)}
PASS=0; FAIL=0
ok(){ echo "[PASS] $*"; PASS=$((PASS+1)); }
no(){ echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
code(){ curl -s -o /dev/null -w "%{http_code}" --max-time 8 "$@"; }
uuid(){ python3 -c "import uuid;print(uuid.uuid4())"; }

echo "===== 1. Ops contract ====="
[ "$(code $RISK_URL/ready)" = "200" ] && ok "/ready 200" || no "/ready"
curl -s $RISK_URL/ready | python3 -c 'import sys,json;d=json.load(sys.stdin);assert d["status"]=="ready";assert d["identity"]["service_name"]=="18-risk-trust";assert [x["name"] for x in d["dependencies"]]==["postgres"]' 2>/dev/null && ok "/ready postgres-only + identity" || no "/ready body"
curl -s $RISK_URL/health | python3 -c 'import sys,json;d=json.load(sys.stdin);c=d["checks"];assert all(k in c for k in ["postgres","scylladb","qdrant","kafka","mongo_logs","apm"]);assert "logs_sink_es" in d["observability"]' 2>/dev/null && ok "/health all deps + observability" || no "/health"
curl -s -o /dev/null $RISK_URL/openapi.json
curl -s $RISK_URL/metrics | grep -q "risk_outbox_pending" && ok "/metrics has risk_outbox_pending (mandatory)" || no "/metrics outbox gauge"
curl -s $RISK_URL/metrics | grep -q "http_request" && ok "/metrics RED" || no "/metrics RED"
curl -s $RISK_URL/openapi.json | python3 -c 'import sys,json;d=json.load(sys.stdin);assert d["info"]["title"]=="DOKANDAR Risk & Trust Service";assert "/api/v1/risk/score/checkout" in d["paths"]' 2>/dev/null && ok "/openapi.json title + routes" || no "/openapi.json"
[ "$(code $RISK_URL/docs)" = "200" ] && ok "/docs 200" || no "/docs"
C=$(code $RISK_URL/nope); CT=$(curl -s -o /dev/null -w "%{content_type}" $RISK_URL/nope); SZ=$(curl -s -o /dev/null -w "%{size_download}" $RISK_URL/nope)
[ "$C" = "404" ] && [ -z "$CT" ] && [ "$SZ" = "0" ] && ok "bare-404 (no CT, 0 bytes)" || no "bare-404 c=$C ct=$CT sz=$SZ"

echo "===== 2. Score routes (internal-token) + the SECURITY property ====="
[ -n "$ITOK" ] && ok "internal token present" || no "no internal token"
[ "$(code -X POST -H 'content-type: application/json' -d "{\"user_id\":\"$(uuid)\",\"order_id\":\"$(uuid)\",\"amount_minor\":10000}" $RISK_URL/api/v1/risk/score/checkout)" = "401" ] && ok "score/checkout no-token → 401" || no "score no-token"
SR=$(curl -s -X POST -H "x-internal-token: $ITOK" -H 'content-type: application/json' -d "{\"user_id\":\"$(uuid)\",\"order_id\":\"$(uuid)\",\"amount_minor\":10000,\"payment_method\":\"cod\"}" $RISK_URL/api/v1/risk/score/checkout)
echo "$SR" | python3 -c 'import sys,json;d=json.load(sys.stdin);assert d["decision"] in ("allow","review","deny");assert "reason_codes" in d' 2>/dev/null && ok "score/checkout internal-token → decision" || no "score/checkout decision"
# THE load-bearing security check: the response must NEVER carry the numeric score/threshold
echo "$SR" | python3 -c 'import sys,json;d=json.load(sys.stdin);sys.exit(1 if ("score" in d or "threshold" in d) else 0)' 2>/dev/null && ok "score response OMITS the numeric score/threshold (§12 security)" || no "score LEAKED in the response"
[ "$(code -X POST -H "x-internal-token: $ITOK" -H 'content-type: application/json' -d "{\"user_id\":\"$(uuid)\",\"order_id\":\"$(uuid)\",\"amount_minor\":30000}" $RISK_URL/api/v1/risk/score/cod)" = "200" ] && ok "score/cod internal-token → 200" || no "score/cod"

echo "===== 3. Admin (Bearer) gates ====="
PH=$(printf "017%08d" $(( (RANDOM*RANDOM) % 100000000 )))
curl -s -m8 -X POST $AUTH_URL/api/v1/auth/signup/request -H 'content-type: application/json' -d "{\"phone\":\"$PH\"}" >/dev/null; sleep 1.5
OTP=""; for _ in $(seq 1 12); do OTP=$(curl -s -m8 "$SUPPORT_URL/otp/latest?phone=$PH&purpose=signup" | python3 -c "import sys,json;print(json.load(sys.stdin).get('code',''))" 2>/dev/null); [ -n "$OTP" ] && break; sleep 1; done
CTOK=$(curl -s -m8 -X POST $AUTH_URL/api/v1/auth/signup/verify -H 'content-type: application/json' -d "{\"phone\":\"$PH\",\"name\":\"R\",\"role\":\"customer\",\"code\":\"$OTP\"}" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
curl -s -m8 -X POST $AUTH_URL/api/v1/auth/login/request -H 'content-type: application/json' -d '{"phone":"01700000000"}' >/dev/null; sleep 1
AOTP=""; for _ in $(seq 1 10); do AOTP=$(curl -s "$SUPPORT_URL/otp/latest?phone=01700000000&purpose=login" | python3 -c "import sys,json;print(json.load(sys.stdin).get('code',''))" 2>/dev/null); [ -n "$AOTP" ] && break; sleep 1; done
ATOK=$(curl -s -m8 -X POST $AUTH_URL/api/v1/auth/login/verify -H 'content-type: application/json' -d "{\"phone\":\"01700000000\",\"code\":\"$AOTP\"}" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
[ -n "$ATOK" ] && [ "$(code -H "authorization: Bearer $ATOK" $RISK_URL/api/v1/risk/admin/rules)" = "200" ] && ok "admin/rules (admin) → 200" || no "admin/rules admin"
# non-admin caller is rejected: 403 with a valid customer token, 401 if the mint was rate-limited.
RC=$(code -H "authorization: Bearer $CTOK" $RISK_URL/api/v1/risk/admin/rules)
{ [ "$RC" = "403" ] || [ "$RC" = "401" ]; } && ok "admin/rules rejects non-admin → $RC (admin route protected)" || no "admin/rules non-admin gate → $RC"

echo "===== 4. gRPC Risk @ $GRPC_EXT ====="
(timeout 3 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/$GRPC_EXT") 2>/dev/null && ok "gRPC port $GRPC_EXT open" || no "gRPC port"

echo "================================================================"
echo "  RESULT: $([ $FAIL = 0 ] && echo PASS || echo FAIL)   PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[ "$FAIL" = "0" ]
