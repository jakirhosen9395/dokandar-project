#!/usr/bin/env bash
# DOKANDAR — Elastic APM stack contract/smoke test (integrated ES + APM Server + Kibana, via curl).
# Sends a real APM intake event (a transaction with a unique service.name) to APM Server :8200, verifies
# it lands in the Elasticsearch traces-apm-* data stream, checks Kibana is available, then DELETES the
# test docs and PROVES zero residue. Never touches another service's data.
#
#   Usage:  bash test.sh [TARGET]
#     TARGET: a variant folder — bash test.sh 03_docker_single   (reads its .env)
#             a host           — bash test.sh 172.31.9.71        (then pass the secrets via env)
#     Resolves: APM_HOST (target host), APM_PORT/ES_HTTP_PORT/KIBANA_PORT, APM_SECRET_TOKEN, ELASTIC_PASSWORD
#     from the TARGET folder's .env, this folder's .env, or the environment.
#   Client: curl (host) or a curlimages/curl Docker container (--network host).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

ARG="${1:-}"; ENVF=""
case "$ARG" in
  "")        : ;;
  *.env|*/*) ENVF="$ARG" ;;
  *[a-zA-Z]*) [ -d "$HERE/$ARG" ] && ENVF="$HERE/$ARG/.env" || APM_HOST="$ARG" ;;
  *)         APM_HOST="$ARG" ;;
esac
if [ -n "$ENVF" ] && [ -r "$ENVF" ]; then set -a; . "$ENVF"; set +a
elif [ -z "${APM_HOST:-}" ] && [ -r "$HERE/.env" ]; then set -a; . "$HERE/.env"; set +a; fi

HOST="${APM_HOST:-${HOST_IP:-127.0.0.1}}"
APORT="${APM_PORT:-8200}"; ESPORT="${ES_HTTP_PORT:-9200}"; KPORT="${KIBANA_PORT:-5601}"
TOKEN="${APM_SECRET_TOKEN:-}"; ESPW="${ELASTIC_PASSWORD:-}"; ESUSER="${ES_USER:-elastic}"
APMU="http://${HOST}:${APORT}"; ESU="http://${HOST}:${ESPORT}"; KU="http://${HOST}:${KPORT}"

if command -v curl >/dev/null 2>&1; then RUNMODE=host; CURL(){ curl "$@"; }
elif command -v docker >/dev/null 2>&1; then
  RUNMODE=docker; docker image inspect curlimages/curl:latest >/dev/null 2>&1 || docker pull -q curlimages/curl:latest >/dev/null 2>&1 || true
  CURL(){ docker run --rm --network host curlimages/curl:latest "$@"; }
else echo "  ✗ no curl and no docker"; echo "RESULT: FAIL (no client)"; exit 2; fi
cq(){ CURL -s --max-time 20 "$@"; }
es(){ cq -u "${ESUSER}:${ESPW}" "$@"; }

TS="$(date +%Y%m%d_%H%M%S)_$$"; SVC="dokandar_apmtest_${TS}"; RESULT_FILE="$HERE/test-result.txt"
PASS=0; FAIL=0
eq(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %-38s [%s]\n' "$1" "$3"
      else FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %-38s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ es -H 'content-type: application/json' -X POST "${ESU}/traces-apm*/_delete_by_query?refresh=true&ignore_unavailable=true" \
  -d "{\"query\":{\"term\":{\"service.name\":\"${SVC}\"}}}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Elastic APM test   apm=${APMU} es=${HOST}:${ESPORT} kibana=${HOST}:${KPORT}   svc=${SVC}   [mode=${RUNMODE}]"

# 0. APM Server up (HTTP 200 from / — with a secret token the unauthenticated body is minimal, so check
#    the status code, not a version string) + ES auth reachable
ACODE="$(cq -o /dev/null -w '%{http_code}' "${APMU}/" 2>/dev/null)"
if [ "$ACODE" != 200 ]; then printf '  \033[31m✗\033[0m APM Server not reachable at %s (http=%s)\n' "$APMU" "${ACODE:-none}"; echo "RESULT: FAIL (no apm-server)"; exit 1; fi
AV="$(cq -H "Authorization: Bearer ${TOKEN}" "${APMU}/" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
ESVER="$(es "${ESU}/?filter_path=version.number" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
echo "  apm-server v${AV}  elasticsearch v${ESVER:-?}"
eq "apm-server reachable" "ok" "$([ -n "$AV" ] && echo ok || echo no)"
eq "elasticsearch auth"   "ok" "$([ -n "$ESVER" ] && echo ok || echo no)"

# 1. send a real APM intake event (metadata + one transaction) with the secret token
TID="$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"; TRACE="$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
TSU="$(date +%s)000000"
NDJSON="$(printf '%s\n%s\n' \
  "{\"metadata\":{\"service\":{\"name\":\"${SVC}\",\"agent\":{\"name\":\"go\",\"version\":\"2.0.0\"},\"language\":{\"name\":\"go\"}}}}" \
  "{\"transaction\":{\"id\":\"${TID}\",\"trace_id\":\"${TRACE}\",\"type\":\"request\",\"name\":\"GET /dokandar-apm-test\",\"duration\":1.5,\"timestamp\":${TSU},\"sampled\":true,\"span_count\":{\"started\":0}}}")"
CODE="$(printf '%s' "$NDJSON" | cq -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/x-ndjson' --data-binary @- "${APMU}/intake/v2/events")"
eq "intake event accepted (202)" "202" "$CODE"

# 2. verify the trace landed in Elasticsearch (poll for the async index)
N=0; for _ in $(seq 1 15); do
  N="$(es "${ESU}/traces-apm*/_count?ignore_unavailable=true" -H 'content-type: application/json' -d "{\"query\":{\"term\":{\"service.name\":\"${SVC}\"}}}" 2>/dev/null | grep -oE '"count":[0-9]+' | cut -d: -f2)"
  [ "${N:-0}" -ge 1 ] 2>/dev/null && break; sleep 2
done
eq "trace indexed in ES (traces-apm)" "ok" "$([ "${N:-0}" -ge 1 ] 2>/dev/null && echo ok || echo "count=${N:-0}")"

# 3. Kibana available (the APM app UI)
KST="$(cq "${KU}/api/status" 2>/dev/null | grep -o '"level":"available"' | head -1)"
eq "kibana status available" "ok" "$([ -n "$KST" ] && echo ok || echo no)"

# 4. cleanup + PROVE zero residue
cleanup; sleep 2
LEFT="$(es "${ESU}/traces-apm*/_count?ignore_unavailable=true" -H 'content-type: application/json' -d "{\"query\":{\"term\":{\"service.name\":\"${SVC}\"}}}" 2>/dev/null | grep -oE '"count":[0-9]+' | cut -d: -f2)"
eq "post-clean: 0 test traces" "0" "${LEFT:-0}"

TOTAL=$((PASS+FAIL)); STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SUMMARY="Elastic APM test @ ${STAMP}  apm=${APMU}  es=v${ESVER:-?}  mode=${RUNMODE}  ->  ${PASS}/${TOTAL} PASS, ${FAIL} FAIL"
echo ""; echo "=================================================================="
printf '%s\n' "$SUMMARY"; echo "=================================================================="
printf '%s\n' "$SUMMARY" > "$RESULT_FILE" 2>/dev/null || true
if [ "$TOTAL" -gt 0 ] && [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS — APM pipeline OK, test traces deleted, zero residue."; exit 0
else echo "RESULT: FAIL (${FAIL} failing)"; exit 1; fi
