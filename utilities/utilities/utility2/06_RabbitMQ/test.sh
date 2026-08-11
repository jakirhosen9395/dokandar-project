#!/usr/bin/env bash
# DOKANDAR — RabbitMQ contract/smoke test (via the Management HTTP API — needs only curl). Tests ANY
# RabbitMQ node (single OR cluster). Creates a THROWAWAY quorum queue dokandar_rabbittest_<ts>, publishes
# a bilingual-UTF-8 message, gets it back, checks the payload, then DELETES the queue and PROVES zero
# residue. Never touches another queue.
#
#   Usage:  bash test.sh [TARGET]
#     TARGET: a management URL — bash test.sh "http://user:pass@host:15672"
#             a variant folder — bash test.sh 03_docker_single   (reads its .env)
#             an env-file path  — bash test.sh ./03_docker_single/.env
#     Sources (highest first): a URL arg / RABBITMQ_URL → this folder's .env → a per-variant .env →
#     parts (RABBITMQ_DEFAULT_USER/RABBITMQ_DEFAULT_PASS/host/RABBITMQ_MGMT_PORT; default 127.0.0.1:15672).
#   Client: `curl` (host) or, if absent, a `curlimages/curl` Docker container (--network host).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

_U="${RABBITMQ_URL:-}"; ARG="${1:-}"; CONNURL=""; ENVF=""
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
    else echo "  ! env file not found: $ENVF (using RABBITMQ_* env / defaults)" >&2; fi
  elif [ -r "$HERE/.env" ]; then set -a; . "$HERE/.env"; set +a
  else for f in "$HERE"/0*_*/.env /etc/dokandar/.env; do [ -r "$f" ] || continue; set -a; . "$f"; set +a; break; done
  fi
  [ -n "${RABBITMQ_URL:-}" ] && CONNURL="$RABBITMQ_URL"
fi

# parse http[s]://[user:pass@]host:port
U=""; W=""; H=""; P=""
if [ -n "$CONNURL" ]; then
  s="${CONNURL#http://}"; s="${s#https://}"; s="${s%%/*}"
  if [ "${s#*@}" != "$s" ]; then creds="${s%@*}"; hp="${s##*@}"; U="${creds%%:*}"; [ "${creds#*:}" != "$creds" ] && W="${creds#*:}"; else hp="$s"; fi
  H="${hp%%:*}"; [ "${hp#*:}" != "$hp" ] && P="${hp#*:}"
fi
HOST="${H:-${RABBITMQ_HOST:-127.0.0.1}}"; PORT="${P:-${RABBITMQ_MGMT_PORT:-15672}}"
USER_="${U:-${RABBITMQ_DEFAULT_USER:-guest}}"; PASS="${W:-${RABBITMQ_DEFAULT_PASS:-guest}}"
BASE="http://${HOST}:${PORT}"; SAFE="http://${USER_}:****@${HOST}:${PORT}"

# curl runner — host curl, else a curl container (--network host)
if command -v curl >/dev/null 2>&1; then RUNMODE=host; CURL(){ curl "$@"; }
elif command -v docker >/dev/null 2>&1; then
  RUNMODE=docker; docker image inspect curlimages/curl:latest >/dev/null 2>&1 || docker pull -q curlimages/curl:latest >/dev/null 2>&1 || true
  CURL(){ docker run --rm --network host curlimages/curl:latest "$@"; }
else echo "  ✗ no curl and no docker"; echo "RESULT: FAIL (no client)"; exit 2; fi
api(){ CURL -s -u "${USER_}:${PASS}" -H 'content-type: application/json' "$@"; }

TS="$(date +%Y%m%d_%H%M%S)_$$"; Q="dokandar_rabbittest_${TS}"; VH="%2F"; RESULT_FILE="$HERE/test-result.txt"
PASS_N=0; FAIL_N=0
eq(){ if [ "$2" = "$3" ]; then PASS_N=$((PASS_N+1)); printf '  \033[32m✓\033[0m %-34s [%s]\n' "$1" "$3"
      else FAIL_N=$((FAIL_N+1)); printf '  \033[31m✗\033[0m %-34s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ api -X DELETE "$BASE/api/queues/${VH}/${Q}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> RabbitMQ test   ${SAFE}   queue=${Q}   [mode=${RUNMODE}]"

# 0. connectivity + AUTH
OV="$(api "$BASE/api/overview" 2>&1)"
VER="$(printf '%s' "$OV" | grep -o '"rabbitmq_version":"[^"]*"' | head -1 | cut -d'"' -f4)"
if [ -z "$VER" ]; then
  printf '  \033[31m✗\033[0m cannot connect / authenticate to %s\n' "$SAFE"
  printf '     %s\n' "$(printf '%s' "$OV" | head -c 160)"
  echo "RESULT: FAIL (no server / auth)"; exit 1
fi
NODES="$(api "$BASE/api/nodes?columns=name" 2>/dev/null | grep -o '"name"' | wc -l)"
echo "  server v${VER}  nodes=${NODES:-?}"
eq "management API + auth" "ok" "$([ -n "$VER" ] && echo ok || echo no)"

# 1. create a quorum queue
api -X PUT "$BASE/api/queues/${VH}/${Q}" -d '{"durable":true,"arguments":{"x-queue-type":"quorum"}}' >/dev/null 2>&1
eq "create quorum queue" "quorum" "$(api "$BASE/api/queues/${VH}/${Q}?columns=arguments.x-queue-type" 2>/dev/null | grep -o 'quorum' | head -1)"

# 2. publish a message (bilingual UTF-8) to the default exchange, routed by queue name
ROUTED="$(api -X POST "$BASE/api/exchanges/${VH}/amq.default/publish" \
  -d "{\"properties\":{},\"routing_key\":\"${Q}\",\"payload\":\"chal-চাল-rice\",\"payload_encoding\":\"string\"}" 2>/dev/null | grep -o '"routed":true')"
eq "publish (routed)" "true" "$([ -n "$ROUTED" ] && echo true || echo false)"
sleep 1

# 3. get the message back + verify payload
GET="$(api -X POST "$BASE/api/queues/${VH}/${Q}/get" -d '{"count":1,"ackmode":"ack_requeue_false","encoding":"auto"}' 2>/dev/null)"
eq "get message (1)" "1" "$(printf '%s' "$GET" | grep -o '"message_count":[0-9]*' | head -1 | cut -d: -f2 | awk '{print ($1>=0)?1:0}')"
eq "utf-8 bangla round-trip" "ok" "$(printf '%s' "$GET" | grep -q 'চাল' && echo ok || echo no)"

# 4. delete the queue + PROVE zero residue
cleanup; sleep 1
eq "post-clean: 0 test queues" "0" "$(api "$BASE/api/queues/${VH}?columns=name" 2>/dev/null | grep -o 'dokandar_rabbittest_[0-9_]*' | wc -l | tr -d ' ')"

TOTAL=$((PASS_N+FAIL_N)); STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SUMMARY="RabbitMQ test @ ${STAMP}  ${SAFE}  v${VER}  nodes=${NODES:-?}  mode=${RUNMODE}  ->  ${PASS_N}/${TOTAL} PASS, ${FAIL_N} FAIL"
echo ""; echo "=================================================================="
printf '%s\n' "$SUMMARY"; echo "=================================================================="
printf '%s\n' "$SUMMARY" > "$RESULT_FILE" 2>/dev/null || true
if [ "$TOTAL" -gt 0 ] && [ "$FAIL_N" -eq 0 ]; then echo "RESULT: PASS — test queue deleted, zero residue."; exit 0
else echo "RESULT: FAIL (${FAIL_N} failing)"; exit 1; fi
