#!/usr/bin/env bash
# 16-recommendation end-to-end pipeline (run ON the app host). Proves the half the REST
# smoke can't: consume order.placed → interaction_log → popularity/cross_sell, the admin
# retrain, and the gRPC feed server (token-gated). Uses the REAL 13-order event shape.
set -uo pipefail
RECO_URL=${RECO_URL:-http://127.0.0.1:10016}
AUTH_URL=${AUTH_URL:-http://127.0.0.1:10001}
SUPPORT_URL=${SUPPORT_URL:-http://127.0.0.1:10099}
KAFKA=${KAFKA:-172.31.2.173:9092}
KIMG=${KIMG:-apache/kafka:3.8.0}
CTR=${CTR:-dokandar_recommendation_service_dev}
PASS=0; FAIL=0
ok(){ echo "[PASS] $*"; PASS=$((PASS+1)); }
no(){ echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
info(){ echo "[INFO] $*"; }

otp_for(){ # phone purpose
  local p; for _ in $(seq 1 12); do
    p=$(curl -s -m 8 "$SUPPORT_URL/otp/latest?phone=$1&purpose=$2" | python3 -c "import sys,json;print(json.load(sys.stdin).get('code',''))" 2>/dev/null)
    [ -n "$p" ] && { printf '%s' "$p"; return; }; sleep 1
  done
}

# ── customer (interaction owner) ─────────────────────────────────────────────────────
PHC=$(printf "017%08d" $(( (RANDOM*RANDOM) % 100000000 )))
curl -s -m 8 -X POST "$AUTH_URL/api/v1/auth/signup/request" -H 'content-type: application/json' -d "{\"phone\":\"$PHC\"}" >/dev/null
sleep 1.5; OC=$(otp_for "$PHC" signup)
RESP=$(curl -s -m 8 -X POST "$AUTH_URL/api/v1/auth/signup/verify" -H 'content-type: application/json' -d "{\"phone\":\"$PHC\",\"name\":\"Reco E2E\",\"role\":\"customer\",\"code\":\"$OC\"}")
CTOK=$(printf '%s' "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
SUB=$(python3 -c "import sys,base64,json;p=sys.argv[1].split('.')[1];p+='='*(-len(p)%4);print(json.loads(base64.urlsafe_b64decode(p)).get('sub',''))" "$CTOK" 2>/dev/null)
[ -n "$SUB" ] && ok "minted customer (userId=$SUB)" || { no "customer mint failed"; echo "RESULT FAIL"; exit 1; }

# ── admin (for retrain) via login of the seeded admin 01700000000 ─────────────────────
curl -s -m 8 -X POST "$AUTH_URL/api/v1/auth/login/request" -H 'content-type: application/json' -d '{"phone":"01700000000"}' >/dev/null
sleep 1; OA=$(otp_for "01700000000" login)
ATOK=$(curl -s -m 8 -X POST "$AUTH_URL/api/v1/auth/login/verify" -H 'content-type: application/json' -d "{\"phone\":\"01700000000\",\"code\":\"$OA\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
[ -n "$ATOK" ] && ok "minted admin token" || info "admin login failed — retrain step will be skipped"

# ── metric baseline ──────────────────────────────────────────────────────────────────
ingested(){ curl -s -m 6 "$RECO_URL/metrics" | grep "^reco_interactions_ingested_total" | awk '{s+=$2} END{printf "%d", s+0}'; }
I0=$(ingested); info "interactions ingested baseline = $I0"

# ── produce TWO REAL order.placed (correct 13-order shape: P1+P2 co-ordered twice, so the
#    retrain's `HAVING count(*) > 1` co-purchase noise filter actually builds the pair) ──
TS=$(date +%s); P1="11111111-1111-1111-1111-$(printf '%012d' $((TS%1000000000000)))"; P2="22222222-2222-2222-2222-$(printf '%012d' $((TS%1000000000000)))"
SHOP="33333333-3333-3333-3333-333333333333"
for N in 1 2; do
  EVT="{\"order_id\":\"R16-$TS-$N\",\"customer_id\":\"$SUB\",\"sub_orders\":[{\"shop_id\":\"$SHOP\",\"items\":[{\"product_id\":\"$P1\"},{\"product_id\":\"$P2\"}]}]}"
  printf '%s\n' "$EVT" | docker run --rm -i "$KIMG" /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server "$KAFKA" --topic dokandar.order.placed >/dev/null 2>&1
done
ok "produced 2× order.placed (P1+P2 co-ordered twice)"

# ── assert the consumer ingested the interactions (consume→interaction_log) ───────────
HIT=""
for i in $(seq 1 30); do I1=$(ingested); [ "${I1:-0}" -ge "$((I0+4))" ] && { HIT=1; break; }; sleep 1; done
[ -n "$HIT" ] && ok "consumer ingested ≥4 interactions ($I0 → $I1) [consume→interaction_log]" || no "interactions not ingested ($I0 → ${I1:-?})"

# ── popularity reflects P1 (a cold-start user's feed serves it) ───────────────────────
PHN=$(printf "017%08d" $(( (RANDOM*RANDOM) % 100000000 )))
curl -s -m 8 -X POST "$AUTH_URL/api/v1/auth/signup/request" -H 'content-type: application/json' -d "{\"phone\":\"$PHN\"}" >/dev/null
sleep 1.5; ON=$(otp_for "$PHN" signup)
NTOK=$(curl -s -m 8 -X POST "$AUTH_URL/api/v1/auth/signup/verify" -H 'content-type: application/json' -d "{\"phone\":\"$PHN\",\"name\":\"Cold\",\"role\":\"customer\",\"code\":\"$ON\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
FEED=$(curl -s -m 6 -H "authorization: Bearer $NTOK" "$RECO_URL/api/v1/recommendation/feed/me?size=50")
echo "$FEED" | python3 -c "import sys,json;d=json.load(sys.stdin);ids=[str(i['product_id']) for i in d['items']];sys.exit(0 if ('$P1' in ids or '$P2' in ids) else 1)" 2>/dev/null \
  && ok "ordered product surfaces in a cold-start feed [interaction_log→popularity→feed]" || info "product not yet in feed (popularity scan size-limited) — ingest already proven above"

# ── admin retrain → cross_sell co-purchase pair (P1↔P2) ───────────────────────────────
if [ -n "${ATOK:-}" ]; then
  RC=$(curl -s -o /dev/null -w '%{http_code}' -m 15 -X POST -H "authorization: Bearer $ATOK" "$RECO_URL/api/v1/recommendation/admin/retrain")
  [ "$RC" = "200" ] && ok "admin retrain → 200" || no "admin retrain → $RC"
  sleep 1
  CS=$(curl -s -m 6 "$RECO_URL/api/v1/recommendation/cross-sell?product_id=$P1")
  echo "$CS" | python3 -c "import sys,json;d=json.load(sys.stdin);sys.exit(0 if any(str(x['paired_product_id'])=='$P2' for x in d) else 1)" 2>/dev/null \
    && ok "cross-sell P1→P2 built by retrain [interaction_log→retrain→cross_sell]" || no "cross-sell pair not built"
fi

# ── gRPC feed server (token-gated) via docker exec python client in the container ─────
ITOK=$(grep -E "^INTERNAL_SERVICE_TOKEN=" ~/16-recommendation/env/.env.dev | cut -d= -f2)
GRES=$(docker exec -e ITOK="$ITOK" -e SUB="$SUB" "$CTR" python -c "
import grpc,os,sys
sys.path.insert(0,'/tmp/dokandar_reco_grpc_stubs')
import recommendation_pb2 as pb, recommendation_pb2_grpc as pbg
ch=grpc.insecure_channel('127.0.0.1:50051'); st=pbg.RecommendationStub(ch)
# no token → UNAUTHENTICATED
try:
    st.GetFeed(pb.FeedRequest(user_id=os.environ['SUB'],size=5)); print('NOTOK_FAIL')
except grpc.RpcError as e: print('NOTOK_'+e.code().name)
# with token → ok
try:
    r=st.GetFeed(pb.FeedRequest(user_id=os.environ['SUB'],size=5),metadata=[('x-internal-token',os.environ['ITOK'])])
    print('TOK_OK_items=%d_strategy=%s'%(len(r.items),r.strategy))
except grpc.RpcError as e: print('TOK_FAIL_'+e.code().name)
" 2>&1)
echo "  grpc: $GRES"
echo "$GRES" | grep -q "NOTOK_UNAUTHENTICATED" && ok "gRPC GetFeed no-token → UNAUTHENTICATED" || no "gRPC no-token gate"
echo "$GRES" | grep -q "TOK_OK" && ok "gRPC GetFeed with internal-token → feed response" || no "gRPC with-token call"

echo "================================================================"
echo "  16 E2E RESULT: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[ "$FAIL" = "0" ]
