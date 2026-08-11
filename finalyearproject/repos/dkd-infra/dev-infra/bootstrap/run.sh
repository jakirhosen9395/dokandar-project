#!/usr/bin/env bash
# =============================================================================
# DOKANDAR dev-infra BOOTSTRAP — idempotent. Initialises the running dev substrate with the data shapes
# the business application needs:
#   * 59 Kafka topics      (topics.txt — derived from dkd-contracts-spine messaging.yaml@v1.0.0)
#   * 10 RabbitMQ queues   (queues.txt — same source)
#   * per-context PostgreSQL databases (one DB per bounded context; Finance/Custody isolated by DB here,
#                                       by dedicated instance on the future k8s platform per R2)
#   * RustFS object-storage buckets
# Safe to re-run. Requires the `core` (and for buckets, `storage`) profiles to be up.
# Usage:  bash bootstrap/run.sh
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; . ./.env.secrets; set +a
DK="sudo docker"
MC="${MC:-$HOME/bin/mc}"
B=bootstrap

echo "== Kafka topics (59 from contract) =="
existing="$($DK exec dokandar_kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list 2>/dev/null)"
created=0
while read -r t; do
  [ -z "$t" ] && continue
  printf '%s\n' "$existing" | grep -qxF "$t" && continue
  $DK exec dokandar_kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
      --create --topic "$t" --partitions 1 --replication-factor 1 >/dev/null 2>&1 && created=$((created+1))
done < "$B/topics.txt"
total="$($DK exec dokandar_kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list 2>/dev/null | grep -cvE '^__')"
echo "  +$created created; $total non-internal topics present"

echo "== RabbitMQ queues (10 from contract) via mgmt API =="
qok=0
while read -r q; do
  [ -z "$q" ] && continue
  code=$(curl -sS -o /dev/null -w '%{http_code}' -u "$RABBITMQ_DEFAULT_USER:$RABBITMQ_DEFAULT_PASS" \
    -XPUT "http://localhost:${RABBITMQ_MGMT_PORT}/api/queues/%2F/${q}" \
    -H 'content-type: application/json' -d '{"durable":true}')
  [ "$code" = 201 ] || [ "$code" = 204 ] && qok=$((qok+1))
done < "$B/queues.txt"
echo "  $qok queues declared (durable)"

echo "== PostgreSQL per-context databases =="
dbok=0
for ctx in identity catalog custody provenance inventory b2c b2b finance logistics fraud government analytics platform; do
  db="dkd_${ctx}"
  if $DK exec dokandar_postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT 1 FROM pg_database WHERE datname='${db}'" 2>/dev/null | grep -q 1; then :; else
    $DK exec dokandar_postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE DATABASE ${db}" >/dev/null 2>&1
  fi
  dbok=$((dbok+1))
done
echo "  $dbok per-context databases ensured (dkd_<context>)"

echo "== RustFS buckets =="
bok=0
if [ -x "$MC" ]; then
  $MC alias set dkd "http://localhost:${RUSTFS_API_PORT}" "$RUSTFS_ACCESS_KEY" "$RUSTFS_SECRET_KEY" >/dev/null 2>&1
  for b in dkd-documents dkd-custody-artifacts dkd-media dkd-analytics; do
    $MC mb -p "dkd/${b}" >/dev/null 2>&1 && bok=$((bok+1)) || bok=$((bok+1))
  done
  echo "  buckets present: $($MC ls dkd 2>/dev/null | awk '{print $NF}' | tr '\n' ' ')"
else
  echo "  (mc not found at $MC — run 'storage' profile + install mc to create buckets)"
fi
echo "BOOTSTRAP DONE."
