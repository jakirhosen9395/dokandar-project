#!/usr/bin/env bash
# DOKANDAR — Apache Kafka contract/smoke test. Tests ANY Kafka broker (single OR cluster).
# Creates a THROWAWAY topic dokandar_kafkatest_<ts>, produces messages (bilingual UTF-8), consumes them
# back, checks the count + content, then DELETES the topic and PROVES zero residue. Never touches another.
#
#   Usage:  bash test.sh [TARGET]
#     TARGET: a bootstrap server — bash test.sh "host:9092"   (or PLAINTEXT://host:9092)
#             a variant folder   — bash test.sh 03_docker_single   (reads its .env)
#             an env-file path    — bash test.sh ./03_docker_single/.env
#     Sources (highest first): a host:port arg / KAFKA_BOOTSTRAP → this folder's .env → a per-variant .env →
#     parts (KAFKA_ADVERTISED_HOST:KAFKA_BROKER_PORT; default 127.0.0.1:9092).
#   Client: the host's /opt/kafka/bin tools, else an apache/kafka:<ver> Docker container (--network host).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

_B="${KAFKA_BOOTSTRAP:-}"; ARG="${1:-}"; CONNBS=""; ENVF=""
case "$ARG" in
  *://*)     CONNBS="${ARG##*://}" ;;
  *:[0-9]*)  CONNBS="$ARG" ;;
  "")        : ;;
  *.env|*/*) ENVF="$ARG" ;;
  *)         ENVF="$HERE/$ARG/.env" ;;
esac
[ -z "$CONNBS" ] && [ -n "$_B" ] && CONNBS="$_B"
if [ -z "$CONNBS" ]; then
  if [ -n "$ENVF" ]; then
    if   [ -r "$ENVF" ]; then set -a; . "$ENVF"; set +a
    elif [ -f "$ENVF" ]; then echo "  ! env file exists but is NOT READABLE: $ENVF" >&2
    else echo "  ! env file not found: $ENVF (using KAFKA_* env / defaults)" >&2; fi
  elif [ -r "$HERE/.env" ]; then set -a; . "$HERE/.env"; set +a
  else for f in "$HERE"/0*_*/.env /etc/dokandar/.env; do [ -r "$f" ] || continue; set -a; . "$f"; set +a; break; done
  fi
  [ -n "${KAFKA_BOOTSTRAP:-}" ] && CONNBS="$KAFKA_BOOTSTRAP"
fi
if [ -z "$CONNBS" ]; then
  # docker variants use KAFKA_EXTERNAL_PORT (published), native uses KAFKA_BROKER_PORT
  H="${KAFKA_ADVERTISED_HOST:-127.0.0.1}"; P="${KAFKA_EXTERNAL_PORT:-${KAFKA_BROKER_PORT:-9092}}"; CONNBS="${H}:${P}"
fi
BS="$CONNBS"; KAFKA_VERSION="${KAFKA_VERSION:-4.3.0}"; IMG="apache/kafka:${KAFKA_VERSION}"

# runner: host /opt/kafka/bin tools, else apache/kafka container (--network host). -i for stdin (producer).
if [ -x /opt/kafka/bin/kafka-topics.sh ]; then RUNMODE=host; K(){ local t="$1"; shift; /opt/kafka/bin/"$t" "$@"; }
elif command -v docker >/dev/null 2>&1; then
  RUNMODE=docker; docker image inspect "$IMG" >/dev/null 2>&1 || { echo "  (pulling ${IMG}...)"; docker pull -q "$IMG" >/dev/null 2>&1 || true; }
  K(){ local t="$1"; shift; docker run --rm -i --network host "$IMG" /opt/kafka/bin/"$t" "$@"; }
else echo "  ✗ no /opt/kafka/bin and no docker"; echo "RESULT: FAIL (no client)"; exit 2; fi

TS="$(date +%Y%m%d_%H%M%S)_$$"; TOPIC="dokandar_kafkatest_${TS}"; RESULT_FILE="$HERE/test-result.txt"
PASS=0; FAIL=0
eq(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %-34s [%s]\n' "$1" "$3"
      else FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %-34s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ K kafka-topics.sh --bootstrap-server "$BS" --delete --topic "$TOPIC" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Kafka test   bootstrap=${BS}   topic=${TOPIC}   [mode=${RUNMODE}]"

# 0. connectivity
if ! K kafka-broker-api-versions.sh --bootstrap-server "$BS" >/dev/null 2>&1; then
  printf '  \033[31m✗\033[0m cannot reach the Kafka broker at %s\n' "$BS"
  echo "RESULT: FAIL (no broker)"; exit 1
fi
NBROKERS="$(K kafka-broker-api-versions.sh --bootstrap-server "$BS" 2>/dev/null | grep -c 'id:')"
echo "  brokers reachable=${NBROKERS:-?}"
eq "broker reachable" "ok" "$(K kafka-broker-api-versions.sh --bootstrap-server "$BS" >/dev/null 2>&1 && echo ok || echo no)"

# 1. create topic (RF 1 so it works on single AND cluster)
K kafka-topics.sh --bootstrap-server "$BS" --create --topic "$TOPIC" --partitions 1 --replication-factor 1 >/dev/null 2>&1
eq "create topic" "1" "$(K kafka-topics.sh --bootstrap-server "$BS" --list 2>/dev/null | grep -c "^${TOPIC}$")"

# 2. describe (partition count)
eq "describe topic (1 partition)" "1" "$(K kafka-topics.sh --bootstrap-server "$BS" --describe --topic "$TOPIC" 2>/dev/null | grep -c 'Partition:')"

# 3. produce 3 messages (bilingual UTF-8)
printf 'rice\nচাল\noil\n' | K kafka-console-producer.sh --bootstrap-server "$BS" --topic "$TOPIC" >/dev/null 2>&1

# 4. consume them back
OUT="$(K kafka-console-consumer.sh --bootstrap-server "$BS" --topic "$TOPIC" --from-beginning --max-messages 3 --timeout-ms 20000 2>/dev/null)"
eq "consume 3 messages" "3" "$(printf '%s\n' "$OUT" | grep -c .)"
eq "utf-8 bangla round-trip" "চাল" "$(printf '%s\n' "$OUT" | grep -F 'চাল' | head -1)"

# 5. delete the topic + PROVE zero residue
cleanup; sleep 1
eq "post-clean: 0 test topics" "0" "$(K kafka-topics.sh --bootstrap-server "$BS" --list 2>/dev/null | grep -c "^dokandar_kafkatest_")"

TOTAL=$((PASS+FAIL)); STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SUMMARY="Kafka test @ ${STAMP}  bootstrap=${BS}  brokers=${NBROKERS:-?}  mode=${RUNMODE}  ->  ${PASS}/${TOTAL} PASS, ${FAIL} FAIL"
echo ""; echo "=================================================================="
printf '%s\n' "$SUMMARY"; echo "=================================================================="
printf '%s\n' "$SUMMARY" > "$RESULT_FILE" 2>/dev/null || true
if [ "$TOTAL" -gt 0 ] && [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS — test topic deleted, zero residue."; exit 0
else echo "RESULT: FAIL (${FAIL} failing)"; exit 1; fi
