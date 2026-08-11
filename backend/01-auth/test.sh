#!/usr/bin/env bash
# dokandar-auth smoke test — hits the standard contract + the 2-step OTP
# signup → token → /me flow. Posts a pass/fail summary to a Discord webhook.
#
# Run on the host where dokandar_auth_service_dev is up (port 8000).
#   ./test.sh                     # localhost
#   AUTH_URL=http://x:8000 ./test.sh
#
# To override the Discord destination, set DISCORD_WEBHOOK_URL in env.
set -uo pipefail

AUTH_URL="${AUTH_URL:-http://127.0.0.1:8000}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-https://discord.com/api/webhooks/1508908310789619893/lqRtLDxb6-QaYk26ewwVwE-_ixhA2IdTkRdUXxhCMsQQgoC-gsPB6zQ0JQfE_AMhFhfx}"
CONTAINER="${AUTH_CONTAINER:-dokandar_auth_service_dev}"

passed=0; failed=0
results=()

ok()   { results+=("✅ $1"); passed=$((passed + 1)); }
fail() { results+=("❌ $1"); failed=$((failed + 1)); }

check_status() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then ok "$label → HTTP $actual"
    else fail "$label → HTTP $actual (expected $expected)"; fi
}

echo "== contract surface =="
for ep in ready health docs metrics openapi.json; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$AUTH_URL/$ep")
    check_status "GET /$ep" 200 "$code"
done
check_status "GET /foobar (bare 404)" 404 "$(curl -s -o /dev/null -w '%{http_code}' "$AUTH_URL/foobar")"

echo "== /health deps =="
health_body=$(curl -s "$AUTH_URL/health")
if echo "$health_body" | python3 -c 'import sys,json;d=json.load(sys.stdin);sys.exit(0 if d.get("status")=="healthy" else 1)' 2>/dev/null; then
    ok "/health.status = healthy"
    for k in postgres redis kafka rabbitmq mongo_logs apm; do
        if echo "$health_body" | python3 -c "import sys,json;d=json.load(sys.stdin);sys.exit(0 if d['checks'].get('$k',{}).get('ok') else 1)" 2>/dev/null; then
            ok "dep $k healthy"
        else
            fail "dep $k NOT healthy"
        fi
    done
else
    fail "/health.status NOT healthy"
fi

echo "== OTP signup → token → /me =="
PHONE="017$(date +%s | tail -c 9)"
sig_req=$(curl -s -X POST -H "Content-Type: application/json" -d "{\"phone\":\"$PHONE\"}" "$AUTH_URL/api/v1/auth/signup/request")
if echo "$sig_req" | grep -q '"otp_sent"'; then ok "signup/request → otp_sent for $PHONE"
else fail "signup/request unexpected: $(echo "$sig_req" | head -c 120)"; fi

# OTP is logged at WARNING level in dev mode — recover it from the auth container's stdout
sleep 1
CODE=""
if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}\$"; then
    CODE=$(docker logs "$CONTAINER" 2>&1 | grep -E "phone=$PHONE.*code=" | tail -1 | grep -oE 'code=[0-9]+' | grep -oE '[0-9]+')
fi
if [ -n "$CODE" ]; then ok "recovered dev-OTP from container logs"
else fail "could not recover OTP (container=$CONTAINER not visible to this user)"; fi

ACCESS_TOKEN=""
if [ -n "$CODE" ]; then
    verify=$(curl -s -X POST -H "Content-Type: application/json" \
        -d "{\"phone\":\"$PHONE\",\"code\":\"$CODE\",\"name\":\"Smoke Test\",\"role\":\"customer\",\"email\":\"smoke_$(date +%s)@dokandar.com\"}" \
        "$AUTH_URL/api/v1/auth/signup/verify")
    ACCESS_TOKEN=$(echo "$verify" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
    if [ -n "$ACCESS_TOKEN" ]; then ok "signup/verify → access_token issued"
    else fail "signup/verify did NOT return a token: $(echo "$verify" | head -c 120)"; fi
fi

if [ -n "$ACCESS_TOKEN" ]; then
    me=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" "$AUTH_URL/api/v1/auth/me")
    if echo "$me" | python3 -c "import sys,json;d=json.load(sys.stdin);sys.exit(0 if d.get('phone')=='$PHONE' else 1)" 2>/dev/null; then
        ok "GET /auth/me echoes the issued phone"
    else
        fail "GET /auth/me unexpected: $(echo "$me" | head -c 120)"
    fi

    # /auth/me without token should 401
    code=$(curl -s -o /dev/null -w '%{http_code}' "$AUTH_URL/api/v1/auth/me")
    check_status "GET /auth/me unauthenticated → 401" 401 "$code"
fi

# Login-request smoke: just confirms the endpoint accepts the phone we own.
login_req=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
    -d "{\"phone\":\"$PHONE\"}" "$AUTH_URL/api/v1/auth/login/request")
check_status "POST /auth/login/request" 202 "$login_req"

# --- report ---
echo
printf '%s\n' "${results[@]}"
echo
echo "summary: $passed passed / $failed failed"

emoji="✅"
[ $failed -gt 0 ] && emoji="⚠️"
title="${emoji} **dokandar-auth** smoke — \`$passed passed / $failed failed\`"
body=$(printf '%s\n```\n%s\n```\n_host: %s_' "$title" "$(printf '%s\n' "${results[@]}")" "$AUTH_URL")

if [ -n "$DISCORD_WEBHOOK_URL" ]; then
    payload=$(python3 -c 'import sys,json; print(json.dumps({"content": sys.stdin.read()}))' <<< "$body")
    http=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL")
    echo "discord webhook → HTTP $http"
fi

exit $failed
