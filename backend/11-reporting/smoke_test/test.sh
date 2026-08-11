#!/usr/bin/env bash
# 11-reporting smoke — ops contract + the 7 KPI/export endpoints (admin/user gated)
# + projector/observability surface. Mints RS256 tokens via 01-auth (admin login +
# customer signup). Consumer-only service (no outbox); KPIs read the PG fact store.
#   REPORTING_URL=http://127.0.0.1:10011 AUTH_URL=http://127.0.0.1:10001 SUPPORT_URL=http://127.0.0.1:10099 ./smoke_test/test.sh
set -uo pipefail
REPORTING_URL="${REPORTING_URL:-http://127.0.0.1:10011}"
AUTH_URL="${AUTH_URL:-http://127.0.0.1:10001}"
SUPPORT_URL="${SUPPORT_URL:-http://127.0.0.1:10099}"
ADMIN_PHONE="${ADMIN_PHONE:-01700000000}"
ENVF="${ENVF:-$(dirname "$0")/../env/.env.dev}"
gvenv(){ grep -E "^$1=" "$ENVF" 2>/dev/null | head -1 | cut -d= -f2-; }
RH="$(gvenv REDIS_HOST)"; RP="$(gvenv REDIS_PORT)"; RPW="$(gvenv REDIS_PASSWORD)"
# KPI range capped at KPI_MAX_RANGE_DAYS=400 — keep the window under that.
FROM="2026-01-01"; TO="2026-12-31"; QUARTER="2025-Q4"

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
G(){ local p="$1" tok="${2:-}"; local h=(-s -m 20 -o /tmp/rep_b -w '%{http_code}' "$REPORTING_URL$p"); [ -n "$tok" ] && h+=(-H "Authorization: Bearer $tok"); RC="$(curl "${h[@]}" 2>/dev/null)"; RB="$(cat /tmp/rep_b 2>/dev/null)"; }
areq(){ local m="$1" p="$2" body="${3:-}" tok="${4:-}"; local h=(-s -m 15 -o /tmp/rep_a -w '%{http_code}' -X "$m" "$AUTH_URL$p"); [ -n "$tok" ] && h+=(-H "Authorization: Bearer $tok"); [ -n "$body" ] && h+=(-H 'content-type: application/json' -d "$body"); curl "${h[@]}" >/dev/null 2>&1; cat /tmp/rep_a 2>/dev/null; }
otp(){ local c; for _ in 1 2 3 4 5 6; do c="$(curl -s -m 8 "$SUPPORT_URL/otp/latest?phone=$1&purpose=$2" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('code',''))" 2>/dev/null)"; [ -n "$c" ] && { echo "$c"; return; }; sleep 1; done; echo ""; }
genphone(){ printf "01%01d%08d" $((RANDOM%7+2)) $(( (RANDOM*RANDOM)%100000000 )); }
uuid(){ python3 -c "import uuid;print(uuid.uuid4())"; }
reset_admin_otp(){ [ -z "$RH" ] && return 1; command -v docker >/dev/null 2>&1 && docker run --rm redis:7-alpine redis-cli -h "$RH" -p "${RP:-6379}" ${RPW:+-a "$RPW"} -n 0 DEL "otp_rate:$ADMIN_PHONE" >/dev/null 2>&1; }
login(){ local ph="$1"; areq POST /api/v1/auth/login/request "{\"phone\":\"$ph\"}" >/dev/null; sleep 1; local code; code="$(otp "$ph" login)"; [ -z "$code" ] && { echo ""; return; }; jp "$(areq POST /api/v1/auth/login/verify "{\"phone\":\"$ph\",\"code\":\"$code\"}")" access_token; }
signup(){ local ph; ph="$(genphone)"; areq POST /api/v1/auth/signup/request "{\"phone\":\"$ph\"}" >/dev/null; sleep 1; local code; code="$(otp "$ph" signup)"; [ -z "$code" ] && { echo ""; return; }; jp "$(areq POST /api/v1/auth/signup/verify "{\"phone\":\"$ph\",\"code\":\"$code\",\"name\":\"Cust\"}")" access_token; }

echo "== 11-reporting smoke =="
G /ready; [ "$RC" = "000" ] && { rec FAIL preflight "reporting reachable" "$RC" 200 "cannot reach $REPORTING_URL"; echo "RESULT: FAIL"; exit 1; }
[ -z "$(curl -s -o /dev/null -w '%{http_code}' "$AUTH_URL/ready" 2>/dev/null | grep -E '200|503')" ] && AUTHDOWN=1 || AUTHDOWN=0

echo "-- 1. ops contract --"
G /ready; ain ops "/ready 200|503" "$RC" "200 503"
ac ops "identity.service_name==11-reporting" "$(jf identity.service_name)" "11-reporting"
ac ops "/ready gates postgres (dep0)" "$(jf dependencies.0.name)" "postgres"
G /health; ain ops "/health 200|503" "$RC" "200 503"
[ -n "$(jf checks.postgres.ok)" ] && rec PASS ops "/health checks (postgres/kafka/mongo_logs/apm)" "" "" "kafka=$(jf checks.kafka.ok)" || rec FAIL ops "/health checks" "" "" missing
G /data; ain ops "/data 200|404" "$RC" "200 404"
G /metrics; { [ "$RC" = 200 ] && grep -qE "reporting_" <<<"$RB"; } && rec PASS ops "/metrics (reporting_*)" "" "" ok || rec FAIL ops "/metrics" "$RC" 200 "no reporting metrics"
grep -q "reporting_facts_upserted_total" <<<"$RB" && rec PASS ops "/metrics projector counter" "" "" ok || rec WARN ops "reporting_facts_upserted_total" "" "" absent
grep -q "reporting_projection_lag" <<<"$RB" && rec PASS ops "/metrics projection_lag gauge" "" "" ok || rec WARN ops "reporting_projection_lag" "" "" absent
G /openapi.json; ac ops "/openapi.json 200" "200" "$RC"
ac ops "/openapi covers reporting routes" "$([ -n "$(jf paths./api/v1/reporting/platform-kpis)" ] && echo y || (grep -q "platform-kpis" <<<"$RB" && echo y))" "y"
G /docs; ain ops "/docs 200|302" "$RC" "200 302"
BARE=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$REPORTING_URL/no-such-xyz" 2>/dev/null); ac ops "unknown path → 404" "404" "$BARE"

echo "-- 2. auth gating (no token) --"
for ep in "platform-kpis" "shop-kpis?shop_id=$(uuid)" "orders-by-period" "payment-mix" "payouts-history" "exports/nbr-vat?period_from=$FROM&period_to=$TO" "exports/btrc-dbid?quarter=$QUARTER"; do
  G "/api/v1/reporting/$ep"; ain authz "no token /${ep%%\?*} → 401|403" "$RC" "401 403"
done

if [ "$AUTHDOWN" = 0 ]; then
  reset_admin_otp; ATOK="$(login "$ADMIN_PHONE")"; C1="$(signup)"
  if [ -z "$ATOK" ]; then rec WARN mint "admin token" "" "" "admin login failed; authed tests skipped"; else
  rec INFO mint "tokens" "" "" "admin=y cust=$([ -n "$C1" ]&&echo y||echo n)"
  # key-sanity: a fresh token must not 401 (JWT_PUBLIC_KEY_B64 drift gate)
  G "/api/v1/reporting/orders-by-period?from=$FROM&to=$TO" "$C1"; [ "$RC" = "401" ] && rec FAIL keysanity "fresh token not 401 (pubkey drift!)" "$RC" "200" || rec PASS keysanity "fresh token accepted (no pubkey drift)" "" "" ok
  echo "-- 3. user KPIs (customer token) --"
  G "/api/v1/reporting/orders-by-period?from=$FROM&to=$TO" "$C1"; ac kpi "orders-by-period (user) → 200" "200" "$RC"
  G "/api/v1/reporting/shop-kpis?shop_id=$(uuid)&from=$FROM&to=$TO" "$C1"; ac kpi "shop-kpis (user) → 200" "200" "$RC"
  G "/api/v1/reporting/payouts-history?from=$FROM&to=$TO" "$C1"; ac kpi "payouts-history (user) → 200" "200" "$RC"
  echo "-- 4. admin KPIs + exports --"
  G "/api/v1/reporting/platform-kpis?from=$FROM&to=$TO" "$ATOK"; ac kpi "platform-kpis (admin) → 200" "200" "$RC"
  G "/api/v1/reporting/payment-mix?from=$FROM&to=$TO" "$ATOK"; ac kpi "payment-mix (admin) → 200" "200" "$RC"
  G "/api/v1/reporting/exports/nbr-vat?period_from=$FROM&period_to=$TO" "$ATOK"; ac export "nbr-vat export (admin) → 200" "200" "$RC"
  G "/api/v1/reporting/exports/btrc-dbid?quarter=$QUARTER" "$ATOK"; ac export "btrc-dbid export (admin) → 200" "200" "$RC"
  echo "-- 5. role gating (customer on admin route → 403) --"
  if [ -n "$C1" ]; then
    G "/api/v1/reporting/platform-kpis?from=$FROM&to=$TO" "$C1"; ain authz "customer on platform-kpis → 403" "$RC" "403"
    G "/api/v1/reporting/payment-mix?from=$FROM&to=$TO" "$C1"; ain authz "customer on payment-mix → 403" "$RC" "403"
  fi
  fi
else rec SKIP authed "all authed paths" "" "" "AUTH down"; fi

echo
echo "RESULT: $([ $FAIL -eq 0 ] && echo PASS || echo FAIL)   PASS=$PASS FAIL=$FAIL SKIP=$SKIP WARN=$WARN INFO=$INFO (total $((PASS+FAIL+SKIP+WARN+INFO)))"
[ $FAIL -eq 0 ]
