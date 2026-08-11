#!/usr/bin/env bash
# Elastic APM stack contract test — proves all THREE services genuinely work:
#   ES: auth + health + a throwaway index round-trip (delete + zero residue)
#   Kibana: /api/status answers
#   APM server: reachable; intake REJECTS a wrong token and ACCEPTS the real one
#   bash test.sh [docker-single-node-setup]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARG="${1:-}"
case "$ARG" in
  "") for f in "$HERE"/.env "$HERE"/*-setup/.env; do [ -r "$f" ] && { set -a; . "$f"; set +a; break; }; done ;;
  *)  ENVF="$HERE/$ARG/.env"; [ -r "$ENVF" ] && { set -a; . "$ENVF"; set +a; } ;;
esac
HOST="${APM_HOST:-127.0.0.1}"
ES="http://${HOST}:${ES_PORT:-9200}"; KB="http://${HOST}:${KIBANA_PORT:-5601}"; AP="http://${HOST}:${APM_PORT:-8200}"
EPW="${ELASTIC_PASSWORD:-}"; TOK="${APM_SECRET_TOKEN:-}"

TS="$(date +%s)_$$"; IDX="dki-apmtest-${TS}"; RESULT_FILE="$HERE/test-result.txt"; P=0; F=0
eq(){ if [ "$2" = "$3" ]; then P=$((P+1)); printf '  \033[32m✓\033[0m %-40s [%s]\n' "$1" "$3"
     else F=$((F+1)); printf '  \033[31m✗\033[0m %-40s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ curl -s -u "elastic:${EPW}" -X DELETE "${ES}/${IDX}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Elastic APM stack test  es=${ES} kibana=${KB} apm=${AP}"
eq "ES rejects anonymous (401)"    "401" "$(curl -s -o /dev/null -w '%{http_code}' "${ES}/")"
eq "ES auth + cluster health"      "ok"  "$(curl -s -u "elastic:${EPW}" "${ES}/_cluster/health" | grep -qE '"status":"(green|yellow)"' && echo ok || echo no)"
curl -s -u "elastic:${EPW}" -X PUT "${ES}/${IDX}" -H 'Content-Type: application/json' -d '{"settings":{"number_of_replicas":0}}' >/dev/null
curl -s -u "elastic:${EPW}" -X POST "${ES}/${IDX}/_doc/1?refresh=true" -H 'Content-Type: application/json' -d '{"name_bn":"চাল","qty":100}' >/dev/null
eq "ES index round-trip (UTF-8)"   "চাল" "$(curl -s -u "elastic:${EPW}" "${ES}/${IDX}/_doc/1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["_source"]["name_bn"])' 2>/dev/null)"
eq "Kibana /api/status answers"    "ok"  "$(curl -s -o /dev/null -w '%{http_code}' "${KB}/api/status" | grep -qE '200|401' && echo ok || echo no)"
eq "APM server reachable"          "ok"  "$(curl -s -o /dev/null -w '%{http_code}' "${AP}/" | grep -qE '200|401' && echo ok || echo no)"
NDJSON='{"metadata":{"service":{"name":"dki-smoke","agent":{"name":"manual","version":"0"}}}}
{"transaction":{"id":"0123456789abcdef","trace_id":"0123456789abcdef0123456789abcdef","name":"smoke","type":"request","duration":1,"span_count":{"started":0},"timestamp":'"$(date +%s)"'000000}}'
eq "APM intake rejects wrong token" "401" "$(printf '%s\n' "$NDJSON" | curl -s -o /dev/null -w '%{http_code}' -X POST "${AP}/intake/v2/events" -H 'Content-Type: application/x-ndjson' -H 'Authorization: Bearer WRONG' --data-binary @-)"
eq "APM intake accepts real token"  "202" "$(printf '%s\n' "$NDJSON" | curl -s -o /dev/null -w '%{http_code}' -X POST "${AP}/intake/v2/events" -H 'Content-Type: application/x-ndjson' -H "Authorization: Bearer ${TOK}" --data-binary @-)"
cleanup
eq "post-clean: zero residue"       "0"   "$(curl -s -u "elastic:${EPW}" "${ES}/_cat/indices/dki-apmtest-*?h=index" | grep -c . )"

TOTAL=$((P+F)); SUMMARY="Elastic APM stack test @ $(date -u +%FT%TZ)  ${HOST}  -> ${P}/${TOTAL} PASS, ${F} FAIL"
echo; echo "$SUMMARY"; echo "$SUMMARY" > "$RESULT_FILE"
[ "$F" -eq 0 ] && { echo "RESULT: PASS — test index deleted, zero residue."; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
