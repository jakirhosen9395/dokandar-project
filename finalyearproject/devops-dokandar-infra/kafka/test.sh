#!/usr/bin/env bash
# Kafka contract test — throwaway topic dki_kafkatest_<ts>: create/describe/produce/consume
# (Bangla round-trip)/delete + zero residue. Uses host /opt/kafka/bin tools or an apache/kafka
# container with --network host so a PASS proves the PUBLISHED bootstrap port.
#   bash test.sh [docker-single-node-setup | host:port]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARG="${1:-}"; BS=""
case "$ARG" in
  *:*) BS="$ARG" ;;
  "") for f in "$HERE"/.env "$HERE"/*-setup/.env; do [ -r "$f" ] && { set -a; . "$f"; set +a; break; }; done ;;
  *)  ENVF="$HERE/$ARG/.env"; [ -r "$ENVF" ] && { set -a; . "$ENVF"; set +a; } ;;
esac
[ -z "$BS" ] && BS="127.0.0.1:${KAFKA_EXTERNAL_PORT:-9092}"
IMG="apache/kafka:${KAFKA_VERSION:-4.3.0}"
if [ -x /opt/kafka/bin/kafka-topics.sh ]; then MODE=host; K(){ local t="$1"; shift; /opt/kafka/bin/"$t" "$@"; }
elif command -v docker >/dev/null 2>&1; then MODE=docker; docker image inspect "$IMG" >/dev/null 2>&1 || docker pull -q "$IMG" >/dev/null 2>&1 || true
     K(){ local t="$1"; shift; docker run --rm -i --network host "$IMG" /opt/kafka/bin/"$t" "$@"; }
else echo "no /opt/kafka/bin and no docker"; echo "RESULT: FAIL"; exit 2; fi

TS="$(date +%s)_$$"; TOPIC="dki_kafkatest_${TS}"; RESULT_FILE="$HERE/test-result.txt"; P=0; F=0
eq(){ if [ "$2" = "$3" ]; then P=$((P+1)); printf '  \033[32m✓\033[0m %-34s [%s]\n' "$1" "$3"
     else F=$((F+1)); printf '  \033[31m✗\033[0m %-34s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ K kafka-topics.sh --bootstrap-server "$BS" --delete --topic "$TOPIC" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Kafka test  bootstrap=${BS}  [mode=${MODE}]"
K kafka-broker-api-versions.sh --bootstrap-server "$BS" >/dev/null 2>&1 || { echo "  ✗ cannot reach broker"; echo "RESULT: FAIL (no broker)"; exit 1; }
eq "broker reachable" "ok" "ok"
K kafka-topics.sh --bootstrap-server "$BS" --create --topic "$TOPIC" --partitions 1 --replication-factor 1 >/dev/null 2>&1
eq "create topic"     "1" "$(K kafka-topics.sh --bootstrap-server "$BS" --list 2>/dev/null | grep -c "^${TOPIC}$")"
eq "describe topic"   "1" "$(K kafka-topics.sh --bootstrap-server "$BS" --describe --topic "$TOPIC" 2>/dev/null | grep -c 'Partition:')"
printf 'rice\nচাল\noil\n' | K kafka-console-producer.sh --bootstrap-server "$BS" --topic "$TOPIC" >/dev/null 2>&1
OUT="$(K kafka-console-consumer.sh --bootstrap-server "$BS" --topic "$TOPIC" --from-beginning --max-messages 3 --timeout-ms 20000 2>/dev/null)"
eq "consume 3 messages" "3" "$(printf '%s\n' "$OUT" | grep -c .)"
eq "utf-8 bangla round-trip" "চাল" "$(printf '%s\n' "$OUT" | grep -F 'চাল' | head -1)"
cleanup; sleep 1
eq "post-clean: zero residue" "0" "$(K kafka-topics.sh --bootstrap-server "$BS" --list 2>/dev/null | grep -c '^dki_kafkatest_')"

TOTAL=$((P+F)); SUMMARY="Kafka test @ $(date -u +%FT%TZ)  bootstrap=${BS}  mode=${MODE}  -> ${P}/${TOTAL} PASS, ${F} FAIL"
echo; echo "$SUMMARY"; echo "$SUMMARY" > "$RESULT_FILE"
[ "$TOTAL" -gt 0 ] && [ "$F" -eq 0 ] && { echo "RESULT: PASS — test topic deleted, zero residue."; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
