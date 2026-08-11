#!/usr/bin/env bash
# 12-media smoke — ops contract + the upload→complete→ready→signed-url flow + auth gates + gRPC.
# Mints an RS256 customer token via 01-auth (signup + OTP from 00-support). Presigned PUT/GET go
# straight to the S3/RustFS store (bytes never traverse this service). Exit 0 iff FAIL=0.
#   MEDIA_URL=http://127.0.0.1:10012 AUTH_URL=http://127.0.0.1:10001 SUPPORT_URL=http://127.0.0.1:10099 ./smoke_test/test.sh
set -uo pipefail
MEDIA_URL="${MEDIA_URL:-http://127.0.0.1:10012}"
GRPC_ADDR="${GRPC_ADDR:-127.0.0.1:20012}"
AUTH_URL="${AUTH_URL:-http://127.0.0.1:10001}"
SUPPORT_URL="${SUPPORT_URL:-http://127.0.0.1:10099}"
ENVF="${ENVF:-$(dirname "$0")/../env/.env.dev}"
gvenv(){ grep -E "^$1=" "$ENVF" 2>/dev/null | head -1 | cut -d= -f2-; }
INTERNAL_TOKEN="${INTERNAL_SERVICE_TOKEN:-$(gvenv INTERNAL_SERVICE_TOKEN)}"

PASS=0; FAIL=0; WARN=0; SKIP=0; INFO=0; RC=""; RB=""
rec(){ local st="$1" c="$2" n="$3" g="${4:-}" w="${5:-}" d="${6:-}"; local x=""; [ -n "$g" ] && x=" (HTTP $g${w:+, want $w})"; [ -n "$d" ] && x="$x — $d"; printf "[%s] %s :: %s%s\n" "$st" "$c" "$n" "$x"; case "$st" in PASS)PASS=$((PASS+1));;FAIL)FAIL=$((FAIL+1));;WARN)WARN=$((WARN+1));;SKIP)SKIP=$((SKIP+1));;INFO)INFO=$((INFO+1));;esac; }
ac(){ if [ "$4" = "$3" ]; then rec PASS "$1" "$2" "$4" "$3" "${5:-}"; else rec FAIL "$1" "$2" "$4" "$3" "${5:-}"; fi; }
ain(){ local c="$1" n="$2" a="$3" s="$4" d="${5:-}"; for x in $s; do [ "$a" = "$x" ] && { rec PASS "$c" "$n" "$a" "$s" "$d"; return; }; done; rec FAIL "$c" "$n" "$a" "$s" "$d"; }
jf(){ printf '%s' "$RB" | python3 -c "import sys,json
try:
 d=json.load(sys.stdin)
 for k in sys.argv[1].split('.'): d=d[int(k)] if isinstance(d,list) else d.get(k)
 print('' if d is None else d)
except Exception: print('')" "$1" 2>/dev/null; }
jp(){ printf '%s' "$1" | python3 -c "import sys,json
try:
 d=json.load(sys.stdin)
 for k in sys.argv[1].split('.'): d=d.get(k) if isinstance(d,dict) else None
 print('' if d is None else d)
except Exception: print('')" "$2" 2>/dev/null; }
# G <path> [token] — GET; H <verb> <path> <body> [token] — JSON request to MEDIA_URL
G(){ local p="$1" tok="${2:-}"; local h=(-s -m 20 -o /tmp/m_b -w '%{http_code}' "$MEDIA_URL$p"); [ -n "$tok" ] && h+=(-H "Authorization: Bearer $tok"); RC="$(curl "${h[@]}" 2>/dev/null)"; RB="$(cat /tmp/m_b 2>/dev/null)"; }
H(){ local m="$1" p="$2" body="${3:-}" tok="${4:-}"; local h=(-s -m 20 -o /tmp/m_b -w '%{http_code}' -X "$m" "$MEDIA_URL$p"); [ -n "$tok" ] && h+=(-H "Authorization: Bearer $tok"); [ -n "$body" ] && h+=(-H 'content-type: application/json' -d "$body"); RC="$(curl "${h[@]}" 2>/dev/null)"; RB="$(cat /tmp/m_b 2>/dev/null)"; }
areq(){ local m="$1" p="$2" body="${3:-}" tok="${4:-}"; local h=(-s -m 15 -o /tmp/m_a -w '%{http_code}' -X "$m" "$AUTH_URL$p"); [ -n "$tok" ] && h+=(-H "Authorization: Bearer $tok"); [ -n "$body" ] && h+=(-H 'content-type: application/json' -d "$body"); curl "${h[@]}" >/dev/null 2>&1; cat /tmp/m_a 2>/dev/null; }
otp(){ local c; for _ in 1 2 3 4 5 6; do c="$(curl -s -m 8 "$SUPPORT_URL/otp/latest?phone=$1&purpose=$2" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('code',''))" 2>/dev/null)"; [ -n "$c" ] && { echo "$c"; return; }; sleep 1; done; echo ""; }
genphone(){ printf "01%01d%08d" $((RANDOM%7+2)) $(( (RANDOM*RANDOM)%100000000 )); }
uuid(){ python3 -c "import uuid;print(uuid.uuid4())"; }
signup(){ local ph; ph="$(genphone)"; areq POST /api/v1/auth/signup/request "{\"phone\":\"$ph\"}" >/dev/null; sleep 1; local code; code="$(otp "$ph" signup)"; [ -z "$code" ] && { echo ""; return; }; jp "$(areq POST /api/v1/auth/signup/verify "{\"phone\":\"$ph\",\"code\":\"$code\",\"name\":\"Cust\"}")" access_token; }

echo "== 12-media smoke =="
G /ready; [ "$RC" = "000" ] && { rec FAIL preflight "media reachable" "$RC" 200 "cannot reach $MEDIA_URL"; echo "RESULT: FAIL"; exit 1; }
[ -z "$(curl -s -o /dev/null -w '%{http_code}' "$AUTH_URL/ready" 2>/dev/null | grep -E '200|503')" ] && AUTHDOWN=1 || AUTHDOWN=0

echo "-- 1. ops contract --"
G /ready; ain ops "/ready 200|503" "$RC" "200 503"
ac ops "identity.service_name==12-media" "$(jf identity.service_name)" "12-media"
ac ops "/ready gates postgres (dep0)" "$(jf dependencies.0.name)" "postgres"
ac ops "/ready gates s3 (dep1)" "$(jf dependencies.1.name)" "s3"
G /health; ain ops "/health 200|503" "$RC" "200 503"
[ -n "$(jf checks.postgres.ok)" ] && rec PASS ops "/health checks postgres" "" "" "ok" || rec FAIL ops "/health postgres check" "" "" missing
[ -n "$(jf checks.s3.ok)" ] && rec PASS ops "/health checks s3" "" "" "ok" || rec FAIL ops "/health s3 check" "" "" missing
[ -n "$(jf checks.kafka.ok)" ] && rec PASS ops "/health checks kafka (diag)" "" "" "ok" || rec WARN ops "/health kafka check" "" "" missing
[ -n "$(jf checks.mongo_logs.ok)" ] && rec PASS ops "/health checks mongo_logs (diag)" "" "" "ok" || rec WARN ops "/health mongo_logs check" "" "" missing
[ -n "$(jf checks.elasticsearch.ok)" ] && rec PASS ops "/health checks elasticsearch (diag)" "" "" "ok" || rec WARN ops "/health elasticsearch check" "" "" missing
ac ops "observability.apm_service_name==12-media" "$(jf observability.apm_service_name)" "12-media"
G /data; ain ops "/data 200|404" "$RC" "200 404"
G /metrics; { [ "$RC" = 200 ] && grep -qE "media_" <<<"$RB"; } && rec PASS ops "/metrics (media_*)" "" "" ok || rec FAIL ops "/metrics" "$RC" 200 "no media metrics"
grep -q "media_outbox_pending" <<<"$RB" && rec PASS ops "/metrics media_outbox_pending gauge" "" "" ok || rec FAIL ops "media_outbox_pending" "" "" absent
grep -q "media_signed_urls_total" <<<"$RB" && rec PASS ops "/metrics media_signed_urls_total" "" "" ok || rec WARN ops "media_signed_urls_total" "" "" absent
G /openapi.json; ac ops "/openapi.json 200" "200" "$RC"
ac ops "/openapi covers upload-url" "$([ -n "$(jf paths./api/v1/media/upload-url)" ] && echo y || (grep -q "upload-url" <<<"$RB" && echo y))" "y"
G /docs; ain ops "/docs 200|302" "$RC" "200 302"
BARE_CL="$(curl -s -m 8 -o /dev/null -w '%{http_code}|%{size_download}' "$MEDIA_URL/no-such-xyz" 2>/dev/null)"
ac ops "unknown path → bare 404 (CL:0)" "404|0" "$BARE_CL"

echo "-- 2. auth gating (no token) --"
H POST /api/v1/media/upload-url '{"scope":"generic","kind":"test","mime":"text/plain","max_bytes":1048576}'; ain authz "no token upload-url → 401" "$RC" "401"
G "/api/v1/media/$(uuid)"; ain authz "no token GET media → 401" "$RC" "401"

if [ "$AUTHDOWN" = 0 ]; then
  C1="$(signup)"; C2="$(signup)"
  if [ -z "$C1" ]; then rec WARN mint "customer token" "" "" "signup failed; flow tests skipped"; else
  rec INFO mint "tokens" "" "" "cust1=y cust2=$([ -n "$C2" ]&&echo y||echo n)"

  echo "-- 3. upload → complete → ready → signed-url flow --"
  H POST /api/v1/media/upload-url '{"scope":"generic","kind":"test","mime":"text/plain","max_bytes":1048576}' "$C1"
  ac flow "upload-url → 200" "200" "$RC"
  MID="$(jf media_id)"; UP_URL="$(jf upload_url)"
  [ -n "$MID" ] && rec PASS flow "got media_id" "" "" "$MID" || rec FAIL flow "media_id present" "" "" missing
  [ -n "$UP_URL" ] && rec PASS flow "got upload_url (not logged in app)" "" "" "present" || rec FAIL flow "upload_url present" "" "" missing
  # PUT the bytes straight to S3/RustFS via the presigned URL
  TMPF="$(mktemp)"; printf 'hello dokandar media %s\n' "$MID" > "$TMPF"; NBYTES="$(wc -c < "$TMPF" | tr -d ' ')"
  if [ -n "$UP_URL" ]; then
    PUT_RC="$(curl -s -m 20 -o /dev/null -w '%{http_code}' -T "$TMPF" -X PUT "$UP_URL" -H "content-type: text/plain" 2>/dev/null)"
    ain flow "presigned PUT to S3 → 200|204" "$PUT_RC" "200 204"
  fi
  H POST "/api/v1/media/$MID/complete" "{\"sha256\":\"\",\"bytes\":$NBYTES}" "$C1"
  ac flow "complete → 200" "200" "$RC"; ain flow "state after complete" "$(jf state)" "uploaded ready scanned"
  # poll until the in-process worker drives it to ready
  STATE=""; for _ in $(seq 1 15); do G "/api/v1/media/$MID" "$C1"; STATE="$(jf state)"; [ "$STATE" = "ready" ] && break; sleep 1; done
  ac flow "worker drives state → ready" "ready" "$STATE"
  G "/api/v1/media/$MID/signed-url?variant=original" "$C1"; ac flow "signed-url (ready) → 200" "200" "$RC"
  SU="$(jf signed_url)"; [ -n "$SU" ] && rec PASS flow "got signed_url" "" "" present || rec FAIL flow "signed_url present" "" "" missing
  if [ -n "$SU" ]; then GET_RC="$(curl -s -m 20 -o /tmp/m_dl -w '%{http_code}' "$SU" 2>/dev/null)"; ain flow "GET signed_url from S3 → 200" "$GET_RC" "200"; fi

  echo "-- 4. authz gates --"
  G "/api/v1/media/$(uuid)" "$C1"; ain authz "unknown id → 404" "$RC" "404"
  if [ -n "$C2" ] && [ -n "$MID" ]; then
    G "/api/v1/media/$MID/signed-url?variant=original" "$C2"; ain authz "non-owner signed-url → 403" "$RC" "403"
  else rec SKIP authz "non-owner signed-url" "" "" "no 2nd token"; fi
  rm -f "$TMPF"
  fi
else rec SKIP authed "all authed paths" "" "" "AUTH down"; fi

echo "-- 5. gRPC (x-internal-token) --"
# The tonic server ships no reflection, so grpcurl needs the proto to resolve the method.
PROTO_DIR="$(cd "$(dirname "$0")/../proto" && pwd 2>/dev/null || echo "")"
if command -v grpcurl >/dev/null 2>&1 && [ -n "${MID:-}" ] && [ -n "$INTERNAL_TOKEN" ] && [ -n "$PROTO_DIR" ]; then
  GC=(-plaintext -import-path "$PROTO_DIR" -proto media.proto)
  OK_RC="$(grpcurl "${GC[@]}" -H "x-internal-token: $INTERNAL_TOKEN" -d "{\"media_id\":\"$MID\"}" "$GRPC_ADDR" dokandar.media.v1.Media/GetMedia 2>&1)"
  grep -q "$MID" <<<"$OK_RC" && rec PASS grpc "GetMedia with token → ok" "" "" ok || rec WARN grpc "GetMedia with token" "" "" "$(printf '%s' "$OK_RC" | head -1)"
  NO_RC="$(grpcurl "${GC[@]}" -d "{\"media_id\":\"$MID\"}" "$GRPC_ADDR" dokandar.media.v1.Media/GetMedia 2>&1)"
  grep -qi "Unauthenticated" <<<"$NO_RC" && rec PASS grpc "GetMedia without token → Unauthenticated" "" "" ok || rec FAIL grpc "GetMedia without token" "" "" "expected Unauthenticated, got: $(printf '%s' "$NO_RC" | head -1)"
else
  rec SKIP grpc "gRPC checks" "" "" "grpcurl/MID/INTERNAL_TOKEN/proto unavailable"
fi

echo
echo "RESULT: $([ $FAIL -eq 0 ] && echo PASS || echo FAIL)   PASS=$PASS FAIL=$FAIL SKIP=$SKIP WARN=$WARN INFO=$INFO (total $((PASS+FAIL+SKIP+WARN+INFO)))"
[ $FAIL -eq 0 ]
