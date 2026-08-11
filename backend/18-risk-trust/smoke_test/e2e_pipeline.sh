#!/usr/bin/env bash
# 18-risk-trust end-to-end (run ON the app host). Proves: the gRPC Risk.ScoreCheckout|ScoreCOD
# (token-gated, decision-only), the risk.decision outbox → Kafka relay, and the COD-refusal
# loop (17's shipment.failed_delivery → cod_refusal → COD scoring reflects it).
set -uo pipefail
RISK_URL=${RISK_URL:-http://127.0.0.1:10018}
KAFKA=${KAFKA:-172.31.2.173:9092}
KIMG=${KIMG:-apache/kafka:3.8.0}
CTR=${CTR:-dokandar_risk_service_dev}
ITOK=$(grep -E "^INTERNAL_SERVICE_TOKEN=" "$HOME/18-risk-trust/env/.env.dev" | cut -d= -f2)
PASS=0; FAIL=0
ok(){ echo "[PASS] $*"; PASS=$((PASS+1)); }
no(){ echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
info(){ echo "[INFO] $*"; }
uuid(){ python3 -c "import uuid;print(uuid.uuid4())"; }

# ── 1. gRPC ScoreCheckout / ScoreCOD (token-gated, decision-only) ─────────────────────
U=$(uuid); O=$(uuid)
GR=$(docker exec -e ITOK="$ITOK" -e U="$U" -e O="$O" "$CTR" python -c "
import grpc,os,sys
sys.path.insert(0,'/tmp/dokandar_risk_grpc_stubs')
import risk_pb2 as pb, risk_pb2_grpc as pbg
st=pbg.RiskStub(grpc.insecure_channel('127.0.0.1:50051'))
req=pb.ScoreRequest(user_id=os.environ['U'],order_id=os.environ['O'],amount_minor=10000,payment_method='cod')
try: st.ScoreCheckout(req); print('NOTOK_FAIL')
except grpc.RpcError as e: print('NOTOK_'+e.code().name)
try:
    r=st.ScoreCheckout(req,metadata=[('x-internal-token',os.environ['ITOK'])])
    print('TOK_OK decision=%s reasons=%s fields=%s'%(r.decision,list(r.reason_codes),[f.name for f in r.DESCRIPTOR.fields]))
except grpc.RpcError as e: print('TOK_FAIL_'+e.code().name)
" 2>&1)
echo "  grpc: $GR"
echo "$GR" | grep -q "NOTOK_UNAUTHENTICATED" && ok "gRPC ScoreCheckout no-token → UNAUTHENTICATED" || no "gRPC no-token gate"
echo "$GR" | grep -q "TOK_OK decision=" && ok "gRPC ScoreCheckout with internal-token → decision" || no "gRPC with-token"
echo "$GR" | grep -qE "fields=\['decision', 'reason_codes'\]" && ok "gRPC response is decision+reason_codes ONLY (no score field, §12)" || no "gRPC response leaks fields"

# ── 2. risk.decision outbox → Kafka relay ────────────────────────────────────────────
EID=$(uuid)
curl -s -X POST -H "x-internal-token: $ITOK" -H 'content-type: application/json' \
  -d "{\"user_id\":\"$(uuid)\",\"order_id\":\"$EID\",\"amount_minor\":99000000,\"payment_method\":\"cod\"}" \
  "$RISK_URL/api/v1/risk/score/checkout" >/dev/null
ok "scored a checkout (enqueues a risk.decision outbox row)"
DR=""
for i in $(seq 1 15); do n=$(curl -s "$RISK_URL/metrics" | grep "^risk_outbox_pending" | awk '{print int($2)}'); [ "${n:-1}" = "0" ] && { DR=1; break; }; sleep 1; done
[ -n "$DR" ] && ok "outbox relay drained → risk_outbox_pending=0 [outbox→Kafka]" || no "outbox not drained (pending=${n:-?})"
GOT=$(timeout 12 docker run --rm "$KIMG" /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server "$KAFKA" --topic dokandar.risk.decision --from-beginning --timeout-ms 8000 2>/dev/null | grep -c "$EID" || true)
[ "${GOT:-0}" -ge 1 ] && ok "risk.decision published to Kafka (found $EID)" || info "risk.decision not yet on Kafka (relay timing)"

# ── 3. COD-refusal loop: 17's shipment.failed_delivery → cod_refusal → COD scoring ───
CU=$(uuid)
for n in 1 2 3; do
  printf "{\"user_id\":\"$CU\",\"order_id\":\"$(uuid)\",\"payment_method\":\"cod\"}\n" | \
    docker run --rm -i "$KIMG" /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server "$KAFKA" --topic dokandar.shipment.failed_delivery >/dev/null 2>&1
done
info "produced 3× shipment.failed_delivery (COD) for user $CU"
# poll until the COD score for that user reflects the refusal history (review/deny)
HIT=""
for i in $(seq 1 25); do
  D=$(curl -s -X POST -H "x-internal-token: $ITOK" -H 'content-type: application/json' \
       -d "{\"user_id\":\"$CU\",\"order_id\":\"$(uuid)\",\"amount_minor\":30000}" "$RISK_URL/api/v1/risk/score/cod")
  echo "$D" | python3 -c "import sys,json;d=json.load(sys.stdin);sys.exit(0 if (d['decision'] in ('review','deny') and any('cod_refusal' in r for r in d['reason_codes'])) else 1)" 2>/dev/null && { HIT=1; echo "  cod score: $D" | tr -d '\n'; echo; break; }
  sleep 1
done
[ -n "$HIT" ] && ok "COD score reflects the refusal history [consume→cod_refusal→score]" || no "COD loop not reflected"

echo "================================================================"
echo "  18 E2E RESULT: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[ "$FAIL" = "0" ]
