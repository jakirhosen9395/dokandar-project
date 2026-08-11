#!/usr/bin/env bash
# DOKANDAR — Prometheus contract/smoke test (HTTP API, via curl). Tests ANY Prometheus (single, replica,
# or a Thanos Querier). Prometheus is PULL-based, so this is a READ-ONLY smoke: it checks health/readiness,
# the build version, queries the `up` metric (Prometheus scrapes itself), and confirms a scrape target is
# up. No throwaway data is written, so there is nothing to clean up.
#
#   Usage:  bash test.sh [TARGET]
#     TARGET: a base URL — bash test.sh "http://host:9090"
#             a variant folder — bash test.sh 03_docker_single   (reads its .env)
#             an env-file path  — bash test.sh ./03_docker_single/.env
#     Sources (highest first): a URL arg / PROM_URL → this folder's .env → a per-variant .env →
#     parts (PROM_HOST/PROMETHEUS_PORT; default 127.0.0.1:9090).
#   Client: curl (host) or a curlimages/curl Docker container (--network host).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

_U="${PROM_URL:-}"; ARG="${1:-}"; CONNURL=""; ENVF=""
case "$ARG" in
  http://*|https://*) CONNURL="$ARG" ;;
  "")        : ;;
  *.env|*/*) ENVF="$ARG" ;;
  *)         ENVF="$HERE/$ARG/.env" ;;
esac
[ -z "$CONNURL" ] && [ -n "$_U" ] && CONNURL="$_U"
if [ -z "$CONNURL" ]; then
  if [ -n "$ENVF" ]; then
    if   [ -r "$ENVF" ]; then set -a; . "$ENVF"; set +a
    elif [ -f "$ENVF" ]; then echo "  ! env file exists but is NOT READABLE: $ENVF" >&2
    else echo "  ! env file not found: $ENVF (using PROM_* env / defaults)" >&2; fi
  elif [ -r "$HERE/.env" ]; then set -a; . "$HERE/.env"; set +a
  else for f in "$HERE"/0*_*/.env /etc/dokandar/.env; do [ -r "$f" ] || continue; set -a; . "$f"; set +a; break; done
  fi
  [ -n "${PROM_URL:-}" ] && CONNURL="$PROM_URL"
fi
if [ -n "$CONNURL" ]; then BASE="${CONNURL%/}"
else BASE="http://${PROM_HOST:-127.0.0.1}:${PROMETHEUS_PORT:-9090}"; fi

if command -v curl >/dev/null 2>&1; then RUNMODE=host; CURL(){ curl "$@"; }
elif command -v docker >/dev/null 2>&1; then
  RUNMODE=docker; docker image inspect curlimages/curl:latest >/dev/null 2>&1 || docker pull -q curlimages/curl:latest >/dev/null 2>&1 || true
  CURL(){ docker run --rm --network host curlimages/curl:latest "$@"; }
else echo "  ✗ no curl and no docker"; echo "RESULT: FAIL (no client)"; exit 2; fi
cq(){ CURL -s --max-time 15 "$@"; }

RESULT_FILE="$HERE/test-result.txt"; PASS=0; FAIL=0
eq(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %-36s [%s]\n' "$1" "$3"
      else FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %-36s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }

echo "==> Prometheus test   ${BASE}   [mode=${RUNMODE}]"

# 0. healthy + ready via HTTP 200 (Prometheus returns "...Healthy", a Thanos Querier returns "OK" — so
#    check the status code, not the body)
HCODE="$(cq -o /dev/null -w '%{http_code}' "$BASE/-/healthy" 2>/dev/null)"
if [ "$HCODE" != 200 ]; then
  printf '  \033[31m✗\033[0m not reachable / not healthy at %s (http=%s)\n' "$BASE" "${HCODE:-none}"
  echo "RESULT: FAIL (no server)"; exit 1
fi
eq "/-/healthy (200)" "200" "$HCODE"
eq "/-/ready (200)"   "200" "$(cq -o /dev/null -w '%{http_code}' "$BASE/-/ready" 2>/dev/null)"

# 1. build version
VER="$(cq "$BASE/api/v1/status/buildinfo" 2>/dev/null | grep -oE '"version":"[^"]*"' | head -1 | cut -d'"' -f4)"
[ -n "$VER" ] || VER="$(cq "$BASE/api/v1/status/buildinfo" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
echo "  version v${VER:-?}"
eq "buildinfo (version)" "ok" "$([ -n "$VER" ] && echo ok || echo no)"

# 2. instant query: up  (Prometheus scrapes itself -> up == 1). Poll: the FIRST scrape takes ~1 interval
#    after start, so the `up` series may not exist for the first ~15s.
UPQ=""; for _ in $(seq 1 20); do UPQ="$(cq "$BASE/api/v1/query?query=up" 2>/dev/null)"; printf '%s' "$UPQ" | grep -qE '"value":\[[0-9.]+,"1"\]' && break; sleep 2; done
eq "query 'up' status=success" "success" "$(printf '%s' "$UPQ" | grep -oE '"status":"[^"]*"' | head -1 | cut -d'"' -f4)"
eq "query 'up' has a series" "ok" "$(printf '%s' "$UPQ" | grep -q '"__name__":"up"' && echo ok || echo no)"

# 3. a value of up==1 (at least one target up)
eq "at least one up==1" "ok" "$(printf '%s' "$UPQ" | grep -qE '"value":\[[0-9.]+,"1"\]' && echo ok || echo no)"

# 4. targets endpoint reports an active target
TGT="$(cq "$BASE/api/v1/targets?state=active" 2>/dev/null)"
eq "active scrape target present" "ok" "$(printf '%s' "$TGT" | grep -q '"health":"up"' && echo ok || echo no)"

TOTAL=$((PASS+FAIL)); STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SUMMARY="Prometheus test @ ${STAMP}  ${BASE}  v${VER:-?}  mode=${RUNMODE}  ->  ${PASS}/${TOTAL} PASS, ${FAIL} FAIL"
echo ""; echo "=================================================================="
printf '%s\n' "$SUMMARY"; echo "=================================================================="
printf '%s\n' "$SUMMARY" > "$RESULT_FILE" 2>/dev/null || true
if [ "$TOTAL" -gt 0 ] && [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS — Prometheus healthy, querying, scraping (read-only)."; exit 0
else echo "RESULT: FAIL (${FAIL} failing)"; exit 1; fi
