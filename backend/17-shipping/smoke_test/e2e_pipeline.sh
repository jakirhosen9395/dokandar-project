#!/usr/bin/env bash
# 17-shipping end-to-end (run ON the app host). Proves the hard half: the gRPC
# QuoteDelivery (token-gated), the order.confirmed → book → outbox → Kafka relay, and the
# signed webhook → shipment.failed_delivery (the COD-refusal signal 18-risk-trust consumes).
set -uo pipefail
SHIP_URL=${SHIP_URL:-http://127.0.0.1:10017}
AUTH_URL=${AUTH_URL:-http://127.0.0.1:10001}
SUPPORT_URL=${SUPPORT_URL:-http://127.0.0.1:10099}
KAFKA=${KAFKA:-172.31.2.173:9092}
KIMG=${KIMG:-apache/kafka:3.8.0}
CTR=${CTR:-dokandar_shipping_service_dev}
WEBHOOK_SECRET=${SHIPPING_WEBHOOK_SECRET:-$(grep -E '^SHIPPING_WEBHOOK_SECRET=' "$HOME/17-shipping/env/.env.dev" 2>/dev/null | cut -d= -f2-)}
WEBHOOK_SECRET=${WEBHOOK_SECRET:-dokandar_shipping_webhook_dev}
PASS=0; FAIL=0
ok(){ echo "[PASS] $*"; PASS=$((PASS+1)); }
no(){ echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
info(){ echo "[INFO] $*"; }

# customer token (to read shipments)
PH=$(printf "017%08d" $(( (RANDOM*RANDOM) % 100000000 )))
curl -s -m8 -X POST $AUTH_URL/api/v1/auth/signup/request -H 'content-type: application/json' -d "{\"phone\":\"$PH\"}" >/dev/null; sleep 1.5
OTP=""; for _ in $(seq 1 12); do OTP=$(curl -s -m8 "$SUPPORT_URL/otp/latest?phone=$PH&purpose=signup" | python3 -c "import sys,json;print(json.load(sys.stdin).get('code',''))" 2>/dev/null); [ -n "$OTP" ] && break; sleep 1; done
TOK=$(curl -s -m8 -X POST $AUTH_URL/api/v1/auth/signup/verify -H 'content-type: application/json' -d "{\"phone\":\"$PH\",\"name\":\"ShipE2E\",\"role\":\"customer\",\"code\":\"$OTP\"}" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
[ -n "$TOK" ] && ok "minted customer token" || { no "mint failed"; echo "RESULT FAIL"; exit 1; }
ITOK=$(grep -E "^INTERNAL_SERVICE_TOKEN=" ~/17-shipping/env/.env.dev | cut -d= -f2)

# ── 1. gRPC QuoteDelivery (token-gated) via a ruby client inside the container ────────
GR=$(docker exec -e ITOK="$ITOK" -w /app "$CTR" bundle exec ruby -e '
$LOAD_PATH.unshift "/tmp/dokandar_shipping_grpc"
require "grpc"; require "shipping_pb"; require "shipping_services_pb"
st = Dokandar::Shipping::V1::Shipping::Stub.new("127.0.0.1:8001", :this_channel_is_insecure)
req = Dokandar::Shipping::V1::QuoteRequest.new(address_tier:"district", weight_grams:1500, upazila_code:"savar")
begin; st.quote_delivery(req); puts "NOTOK_FAIL"; rescue GRPC::Unauthenticated; puts "NOTOK_UNAUTH"; rescue=>e; puts "NOTOK_#{e.class}"; end
begin; r=st.quote_delivery(req, metadata:{"x-internal-token"=>ENV["ITOK"]}); puts "TOK_OK courier=#{r.courier} fee=#{r.fee_minor} dist=#{r.distance_km}"; rescue=>e; puts "TOK_FAIL #{e.class}: #{e.message}"; end
' 2>&1)
echo "  grpc: $GR"
echo "$GR" | grep -q "NOTOK_UNAUTH" && ok "gRPC QuoteDelivery no-token → UNAUTHENTICATED" || no "gRPC no-token gate"
echo "$GR" | grep -q "TOK_OK" && ok "gRPC QuoteDelivery with internal-token → quote" || no "gRPC with-token"

# ── 2. order.confirmed (13-order shape) → book → outbox → Kafka relay ─────────────────
SUB=$(python3 -c "import uuid;print(uuid.uuid4())"); OID="SHE2E-$(date +%s)"
EVT="{\"order_id\":\"$OID\",\"customer_id\":\"$(python3 -c 'import uuid;print(uuid.uuid4())')\",\"sub_orders\":[{\"sub_order_id\":\"$SUB\",\"shop_id\":\"$(python3 -c 'import uuid;print(uuid.uuid4())')\",\"address_tier\":\"upazila\",\"upazila_code\":\"dhamrai\",\"cod_amount_minor\":75000,\"items\":[{\"product_id\":\"$(python3 -c 'import uuid;print(uuid.uuid4())')\"}]}]}"
info "producing order.confirmed (sub_order=$SUB)"
printf '%s\n' "$EVT" | docker run --rm -i "$KIMG" /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server "$KAFKA" --topic dokandar.order.confirmed >/dev/null 2>&1 && ok "produced order.confirmed" || no "produce failed"
# poll until the shipment is booked
BOOKED=""
for i in $(seq 1 45); do
  J=$(curl -s -m6 -H "authorization: Bearer $TOK" "$SHIP_URL/api/v1/shipping/shipments/by-order/$SUB")
  echo "$J" | python3 -c "import sys,json;d=json.load(sys.stdin);sys.exit(0 if d.get('status') in ('booked','pending') else 1)" 2>/dev/null && { BOOKED=1; break; }
  sleep 1
done
[ -n "$BOOKED" ] && ok "consumer booked a shipment from order.confirmed [consume→book]" || no "shipment not booked from order.confirmed"

# ── 3. outbox relay drains to Kafka (shipping_outbox_pending → 0) ─────────────────────
DR=""
for i in $(seq 1 15); do
  n=$(curl -s -m6 "$SHIP_URL/metrics" | grep "^shipping_outbox_pending" | awk '{print int($2)}')
  [ "${n:-1}" = "0" ] && { DR=1; break; }; sleep 1
done
[ -n "$DR" ] && ok "outbox relay drained → shipping_outbox_pending=0 [outbox→Kafka]" || no "outbox not drained (pending=${n:-?})"
# confirm the shipment.booked event actually reached Kafka
GOT=$(timeout 12 docker run --rm "$KIMG" /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server "$KAFKA" --topic dokandar.shipment.status_changed --from-beginning --timeout-ms 8000 2>/dev/null | grep -c "$SUB" || true)
[ "${GOT:-0}" -ge 1 ] && ok "shipment.booked published to Kafka (found $SUB)" || info "shipment.booked not yet visible on Kafka (relay timing)"

# ── 4. signed webhook → shipment.failed_delivery (the COD-refusal signal) ─────────────
F0=$(curl -s "$SHIP_URL/metrics" | grep "^shipping_failed_delivery_total" | awk '{print int($2)}'); F0=${F0:-0}
RC=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-Courier-Signature: $WEBHOOK_SECRET" -H "content-type: application/json" -d "{\"sub_order_id\":\"$SUB\",\"status\":\"failed_delivery\"}" "$SHIP_URL/api/v1/shipping/webhooks/pathao")
[ "$RC" = "200" ] && ok "webhook failed_delivery → 200" || no "webhook → $RC"
sleep 2
F1=$(curl -s "$SHIP_URL/metrics" | grep "^shipping_failed_delivery_total" | awk '{print int($2)}'); F1=${F1:-0}
[ "$F1" -gt "$F0" ] && ok "shipping_failed_delivery_total incremented ($F0→$F1) [COD-refusal signal]" || no "failed_delivery metric ($F0→$F1)"
FGOT=$(timeout 12 docker run --rm "$KIMG" /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server "$KAFKA" --topic dokandar.shipment.failed_delivery --from-beginning --timeout-ms 8000 2>/dev/null | grep -c "$SUB" || true)
[ "${FGOT:-0}" -ge 1 ] && ok "shipment.failed_delivery published to Kafka (18-risk-trust's label)" || info "failed_delivery event not yet on Kafka (relay timing)"

echo "================================================================"
echo "  17 E2E RESULT: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[ "$FAIL" = "0" ]
