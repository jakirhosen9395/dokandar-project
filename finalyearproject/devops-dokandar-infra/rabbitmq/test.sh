#!/usr/bin/env bash
# RabbitMQ contract test — via the Management HTTP API: declare a throwaway queue
# dki_rabbittest_<ts>, publish + get a message (round-trip), check the UI/overview,
# wrong-password rejection, delete the queue, prove zero residue.
#   bash test.sh [docker-single-node-setup]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARG="${1:-}"
case "$ARG" in
  "") for f in "$HERE"/.env "$HERE"/*-setup/.env; do [ -r "$f" ] && { set -a; . "$f"; set +a; break; }; done ;;
  *)  ENVF="$HERE/$ARG/.env"; [ -r "$ENVF" ] && { set -a; . "$ENVF"; set +a; } ;;
esac
HOST="${RABBITMQ_HOST:-127.0.0.1}"; MPORT="${RABBITMQ_MGMT_PORT:-15672}"
USER_="${RABBITMQ_USER:-dki}"; PASS_="${RABBITMQ_PASSWORD:-}"
API="http://${HOST}:${MPORT}/api"
C(){ curl -s -u "${USER_}:${PASS_}" "$@"; }

TS="$(date +%s)_$$"; Q="dki_rabbittest_${TS}"; RESULT_FILE="$HERE/test-result.txt"; P=0; F=0
eq(){ if [ "$2" = "$3" ]; then P=$((P+1)); printf '  \033[32m✓\033[0m %-36s [%s]\n' "$1" "$3"
     else F=$((F+1)); printf '  \033[31m✗\033[0m %-36s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ C -X DELETE "${API}/queues/%2F/${Q}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> RabbitMQ test  ${HOST}:${MPORT} user=${USER_} (management API)"
eq "overview reachable"  "ok" "$(C "${API}/overview" | grep -q rabbitmq_version && echo ok || echo no)"
C "${API}/overview" | grep -q rabbitmq_version || { echo "RESULT: FAIL (no server)"; exit 1; }
eq "declare queue"       "201-or-204" "$(code=$(C -o /dev/null -w '%{http_code}' -X PUT -H 'content-type:application/json' -d '{"durable":true}' "${API}/queues/%2F/${Q}"); [ "$code" = 201 ] || [ "$code" = 204 ] && echo 201-or-204 || echo "$code")"
eq "publish message"     "true" "$(C -X POST -H 'content-type:application/json' -d '{"properties":{},"routing_key":"'"$Q"'","payload":"চাল-rice-1","payload_encoding":"string"}' "${API}/exchanges/%2F/amq.default/publish" | grep -o '"routed":true' | grep -q true && echo true)"
eq "get message back"    "চাল-rice-1" "$(C -X POST -H 'content-type:application/json' -d '{"count":1,"ackmode":"ack_requeue_false","encoding":"auto"}' "${API}/queues/%2F/${Q}/get" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["payload"])' 2>/dev/null)"
eq "wrong password 401"  "401" "$(curl -s -o /dev/null -w '%{http_code}' -u "${USER_}:WRONG" "${API}/overview")"
cleanup; sleep 1
eq "post-clean: zero residue" "0" "$(C "${API}/queues" | python3 -c 'import sys,json;print(len([q for q in json.load(sys.stdin) if q["name"].startswith("dki_rabbittest_")]))' 2>/dev/null)"

TOTAL=$((P+F)); SUMMARY="RabbitMQ test @ $(date -u +%FT%TZ)  ${HOST}:${MPORT}  -> ${P}/${TOTAL} PASS, ${F} FAIL"
echo; echo "$SUMMARY"; echo "$SUMMARY" > "$RESULT_FILE"
[ "$F" -eq 0 ] && { echo "RESULT: PASS — test queue deleted, zero residue."; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
