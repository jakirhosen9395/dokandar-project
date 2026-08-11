#!/usr/bin/env bash
# dokandar-profile smoke test — verifies the contract surface and exercises
# the auth → Kafka UserCreated → profile shell upsert pipeline by signing
# a fresh customer up through auth and reading them back via /profile/me.
# Posts a pass/fail summary to a Discord webhook.
#
# Run on the host where dokandar_profile_service_dev (port 8010) AND
# dokandar_auth_service_dev (port 8000) are both up.
#   ./test.sh
#   PROFILE_URL=http://x:8010 AUTH_URL=http://x:8000 ./test.sh
#
# Override the destination with DISCORD_WEBHOOK_URL in env.
set -uo pipefail

PROFILE_URL="${PROFILE_URL:-http://127.0.0.1:8010}"
AUTH_URL="${AUTH_URL:-http://127.0.0.1:8000}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-https://discord.com/api/webhooks/1508908310789619893/lqRtLDxb6-QaYk26ewwVwE-_ixhA2IdTkRdUXxhCMsQQgoC-gsPB6zQ0JQfE_AMhFhfx}"
AUTH_CONTAINER="${AUTH_CONTAINER:-dokandar_auth_service_dev}"

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
    code=$(curl -s -o /dev/null -w '%{http_code}' "$PROFILE_URL/$ep")
    check_status "GET /$ep" 200 "$code"
done
check_status "GET /foobar (bare 404)" 404 "$(curl -s -o /dev/null -w '%{http_code}' "$PROFILE_URL/foobar")"

echo "== /health deps =="
health_body=$(curl -s "$PROFILE_URL/health")
if echo "$health_body" | python3 -c 'import sys,json;d=json.load(sys.stdin);sys.exit(0 if d.get("status")=="healthy" else 1)' 2>/dev/null; then
    ok "/health.status = healthy"
    for k in postgres redis kafka mongo_logs apm; do
        if echo "$health_body" | python3 -c "import sys,json;d=json.load(sys.stdin);sys.exit(0 if d['checks'].get('$k',{}).get('ok') else 1)" 2>/dev/null; then
            ok "dep $k healthy"
        else
            fail "dep $k NOT healthy"
        fi
    done
else
    fail "/health.status NOT healthy"
fi

echo "== auth-issued JWT → /profile/me (Kafka consumer integration) =="
PHONE="017$(date +%s | tail -c 9)"
curl -s -X POST -H "Content-Type: application/json" -d "{\"phone\":\"$PHONE\"}" "$AUTH_URL/api/v1/auth/signup/request" >/dev/null
sleep 1

CODE=""
if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -q "^${AUTH_CONTAINER}\$"; then
    CODE=$(docker logs "$AUTH_CONTAINER" 2>&1 | grep -E "phone=$PHONE.*code=" | tail -1 | grep -oE 'code=[0-9]+' | grep -oE '[0-9]+')
fi

ACCESS_TOKEN=""
EXPECTED_NAME="Profile Smoke"
if [ -n "$CODE" ]; then
    verify=$(curl -s -X POST -H "Content-Type: application/json" \
        -d "{\"phone\":\"$PHONE\",\"code\":\"$CODE\",\"name\":\"$EXPECTED_NAME\",\"role\":\"customer\",\"email\":\"prof_smoke_$(date +%s)@dokandar.com\"}" \
        "$AUTH_URL/api/v1/auth/signup/verify")
    ACCESS_TOKEN=$(echo "$verify" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
fi

if [ -z "$ACCESS_TOKEN" ]; then
    fail "could not obtain auth token (check auth service + container name)"
else
    ok "obtained access_token from auth"

    # /profile/me requires the Kafka UserCreated event to have been consumed.
    # Poll up to 10s — the upsert is typically visible within 2–4s.
    me=""
    for i in 1 2 3 4 5 6 7 8 9 10; do
        me=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" "$PROFILE_URL/api/v1/profile/me")
        if echo "$me" | python3 -c "import sys,json;d=json.load(sys.stdin);sys.exit(0 if d.get('profile',{}).get('name')=='$EXPECTED_NAME' else 1)" 2>/dev/null; then
            ok "GET /profile/me populated after ${i}s (Kafka consumer caught up)"
            break
        fi
        sleep 1
    done

    if ! echo "$me" | python3 -c "import sys,json;d=json.load(sys.stdin);sys.exit(0 if d.get('profile',{}).get('name')=='$EXPECTED_NAME' else 1)" 2>/dev/null; then
        fail "/profile/me never populated within 10s: $(echo "$me" | head -c 140)"
    fi

    # PUT — update the shell row
    put=$(curl -s -o /dev/null -w '%{http_code}' -X PUT -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"name":"Updated Smoke","gender":"male"}' \
        "$PROFILE_URL/api/v1/profile/me")
    check_status "PUT /profile/me" 200 "$put"

    # POST an address
    addr=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"label":"home","line1":"Tejgaon","city":"Dhaka","country":"BD"}' \
        "$PROFILE_URL/api/v1/profile/me/addresses")
    check_status "POST /profile/me/addresses" 201 "$addr"

    # Unauthenticated should be rejected
    code=$(curl -s -o /dev/null -w '%{http_code}' "$PROFILE_URL/api/v1/profile/me")
    check_status "GET /profile/me without token → 401" 401 "$code"
fi

# --- report ---
echo
printf '%s\n' "${results[@]}"
echo
echo "summary: $passed passed / $failed failed"

emoji="✅"
[ $failed -gt 0 ] && emoji="⚠️"
title="${emoji} **dokandar-profile** smoke — \`$passed passed / $failed failed\`"
body=$(printf '%s\n```\n%s\n```\n_host: %s (auth: %s)_' "$title" "$(printf '%s\n' "${results[@]}")" "$PROFILE_URL" "$AUTH_URL")

if [ -n "$DISCORD_WEBHOOK_URL" ]; then
    payload=$(python3 -c 'import sys,json; print(json.dumps({"content": sys.stdin.read()}))' <<< "$body")
    http=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL")
    echo "discord webhook → HTTP $http"
fi

exit $failed
