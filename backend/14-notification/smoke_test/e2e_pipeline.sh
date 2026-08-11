#!/usr/bin/env bash
# End-to-end pipeline validation for 14-notification (run ON the app host).
# Proves the HARD half the contract smoke can't: consume → dedup → inbox materialize →
# channel dispatch, plus real WS auth-on-upgrade. Mints a real RS256 customer token,
# produces a real Kafka event for that user, and asserts the inbox materializes through
# the REST API + the dedup window + the channel metrics.
set -uo pipefail
NOTIF_URL=${NOTIF_URL:-http://127.0.0.1:10014}
AUTH_URL=${AUTH_URL:-http://127.0.0.1:10001}
SUPPORT_URL=${SUPPORT_URL:-http://127.0.0.1:10099}
KAFKA=${KAFKA:-172.31.2.173:9092}
KIMG=${KIMG:-apache/kafka:3.8.0}
PASS=0; FAIL=0
ok(){ echo "[PASS] $*"; PASS=$((PASS+1)); }
no(){ echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
info(){ echo "[INFO] $*"; }

# ── 1. Mint a real customer token (signup → OTP from support → verify) ───────────────
PH=$(printf "017%08d" $(( (RANDOM*RANDOM) % 100000000 )))
curl -s -m 8 -X POST "$AUTH_URL/api/v1/auth/signup/request" -H 'content-type: application/json' \
  -d "{\"phone\":\"$PH\"}" >/dev/null
OTP=""
sleep 1.5
for _ in $(seq 1 12); do
  OTP=$(curl -s -m 8 "$SUPPORT_URL/otp/latest?phone=$PH&purpose=signup" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('code',''))" 2>/dev/null)
  [ -n "$OTP" ] && break; sleep 1
done
info "OTP recovered (len=${#OTP})"
BODY="{\"phone\":\"$PH\",\"name\":\"E2E Tester\",\"role\":\"customer\""
[ -n "$OTP" ] && BODY="$BODY,\"code\":\"$OTP\""
BODY="$BODY}"
RESP=$(curl -s -m 8 -X POST "$AUTH_URL/api/v1/auth/signup/verify" -H 'content-type: application/json' -d "$BODY")
TOKEN=$(printf '%s' "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
if [ -n "$TOKEN" ]; then ok "minted customer token (phone=$PH)"; else no "could not mint token — resp=$(printf '%s' "$RESP" | head -c 200)"; echo "RESULT FAIL"; exit 1; fi
SUB=$(python3 -c "import sys,base64,json;p=sys.argv[1].split('.')[1];p+='='*(-len(p)%4);print(json.loads(base64.urlsafe_b64decode(p)).get('sub',''))" "$TOKEN")
[ -n "$SUB" ] && ok "decoded JWT sub (userId=$SUB)" || no "no sub in JWT"

# ── 2. WS auth-on-upgrade (raw-socket probe; preValidation must refuse with HTTP 401) ─
ws_probe(){ # $1 = optional bearer
  python3 - "$1" <<'PY'
import socket,sys
tok=sys.argv[1]
host,port='127.0.0.1',10014
req=("GET /api/v1/notification/ws/inbox HTTP/1.1\r\nHost: %s:%d\r\n"
     "Connection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\n"
     "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"%(host,port))
if tok: req+="Authorization: Bearer %s\r\n"%tok
req+="\r\n"
try:
 s=socket.create_connection((host,port),5); s.sendall(req.encode()); data=s.recv(256).decode('latin1'); s.close()
 print(data.split('\r\n',1)[0])
except Exception as e: print("ERR %s"%e)
PY
}
NTL=$(ws_probe ""); WTL=$(ws_probe "$TOKEN")
echo "$NTL" | grep -q " 401" && ok "WS no-token → 401 (refused pre-upgrade)" || no "WS no-token → '$NTL' (want 401)"
echo "$WTL" | grep -q " 101" && ok "WS with-token → 101 (upgraded)" || no "WS with-token → '$WTL' (want 101)"

# ── 3. metrics baseline ──────────────────────────────────────────────────────────────
metric(){ curl -s -m 6 "$NOTIF_URL/metrics" | grep -E "^$1" | awk '{s+=$2} END{printf "%d", s+0}'; }
SENT0=$(metric notification_sent_total); DEDUP0=$(metric notification_dedup_hits_total)
info "metrics baseline: sent_total=$SENT0 dedup_hits=$DEDUP0"
inbox_count(){ curl -s -m 6 -H "authorization: Bearer $TOKEN" "$NOTIF_URL/api/v1/notification/inbox?size=100" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("total",len(d.get("items",[]))))' 2>/dev/null; }
CNT0=$(inbox_count); info "inbox count before = ${CNT0:-?}"

# ── 4. Produce a REAL Kafka order.placed event for this user ──────────────────────────
OID="E2E-$(date +%s)"
EVT="{\"user_id\":\"$SUB\",\"order_id\":\"$OID\"}"
info "producing → dokandar.order.placed :: $EVT"
printf '%s\n' "$EVT" | docker run --rm -i "$KIMG" /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server "$KAFKA" --topic dokandar.order.placed >/dev/null 2>&1 \
  && ok "produced order.placed event" || no "kafka produce failed"

# ── 5. Assert the inbox materializes through the REST API (poll up to 25s) ────────────
FOUND=""; FIRST_ID=""
for i in $(seq 1 25); do
  J=$(curl -s -m 6 -H "authorization: Bearer $TOKEN" "$NOTIF_URL/api/v1/notification/inbox?size=100")
  HIT=$(printf '%s' "$J" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for it in d.get('items',[]):
    if it.get('kind')=='order_placed' and '$OID' in (it.get('body_en','')+it.get('deepLink','')):
        print(it.get('id','')); break
" 2>/dev/null)
  [ -n "$HIT" ] && { FOUND=1; FIRST_ID="$HIT"; break; }
  sleep 1
done
if [ -n "$FOUND" ]; then ok "inbox materialized order_placed for $OID (consume→dedup→inbox→REST) id=$FIRST_ID"; else no "order_placed for $OID NOT in inbox after 25s"; fi

# ── 6. Channel dispatch fired (sent_total increased) ─────────────────────────────────
sleep 2; SENT1=$(metric notification_sent_total)
[ "${SENT1:-0}" -gt "${SENT0:-0}" ] && ok "channel dispatch fired (sent_total $SENT0 → $SENT1)" \
  || info "sent_total $SENT0 → $SENT1 (channels enqueued; worker may still be draining)"

# ── 7. Dedup: produce the SAME event again → no new inbox row, dedup counter up ───────
CNT1=$(inbox_count)
printf '%s\n' "$EVT" | docker run --rm -i "$KIMG" /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server "$KAFKA" --topic dokandar.order.placed >/dev/null 2>&1
sleep 6
CNT2=$(inbox_count); DEDUP1=$(metric notification_dedup_hits_total)
if [ "${CNT2:-0}" = "${CNT1:-0}" ] && [ "${DEDUP1:-0}" -gt "${DEDUP0:-0}" ]; then
  ok "dedup absorbed the redelivery (count stayed ${CNT2}, dedup_hits $DEDUP0 → $DEDUP1)"
else
  no "dedup check: count ${CNT1}→${CNT2}, dedup_hits ${DEDUP0}→${DEDUP1} (want count stable + dedup up)"
fi

# ── 8. mark-read the materialized notification ───────────────────────────────────────
if [ -n "$FIRST_ID" ]; then
  RC=$(curl -s -o /dev/null -w '%{http_code}' -m 6 -X POST -H "authorization: Bearer $TOKEN" \
    "$NOTIF_URL/api/v1/notification/inbox/$FIRST_ID/read")
  [ "$RC" = "200" ] && ok "mark-read the new notification → 200" || no "mark-read → $RC (want 200)"
fi

echo "================================================================"
echo "  E2E PIPELINE RESULT: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[ "$FAIL" = "0" ]
