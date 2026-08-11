#!/usr/bin/env bash
# =============================================================================
# DOKANDAR dev-infra — READINESS VERIFICATION (functional, by execution).
# Probes every backing service with a REAL operation (not just container state). Exit 0 = all green.
# Checks for the optional `search`/`storage`/`observability` profiles are skipped (SKIP) when those
# containers aren't running, so it is safe to run against any active profile set.
#   Usage:  bash verify.sh            # uses `sudo docker`; override with DK="docker"
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")"
set -a; . ./.env 2>/dev/null; . ./.env.secrets 2>/dev/null; set +a
DK="${DK:-sudo docker}"; MC="${MC:-$HOME/bin/mc}"
fail=0; pass=0
ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad(){  printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }
skip(){ printf '  \033[33m–\033[0m %s (not running)\n' "$1"; }
up(){ $DK ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

echo "── PostgreSQL ──"
if up dokandar_postgres; then
  $DK exec dokandar_postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1 && ok "ready" || bad "pg_isready"
  n=$($DK exec dokandar_postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from pg_database where datname like 'dkd_%'" 2>/dev/null|tr -d '[:space:]')
  [ "$n" = 13 ] && ok "13 per-context databases" || bad "per-context DBs ($n/13)"
  $DK exec dokandar_postgres psql -U "$POSTGRES_USER" -d dkd_catalog -tAc "create table if not exists _probe(x int); insert into _probe values(1); select count(*) from _probe; drop table _probe;" >/dev/null 2>&1 && ok "write/read (dkd_catalog)" || bad "write/read"
else bad "container not running"; fi

echo "── Redis ──"
if up dokandar_redis; then
  $DK exec dokandar_redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning set _probe ok >/dev/null 2>&1 && \
  [ "$($DK exec dokandar_redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning get _probe 2>/dev/null)" = ok ] && ok "auth SET/GET" || bad "SET/GET"
else bad "container not running"; fi

echo "── Kafka (event spine) ──"
if up dokandar_kafka; then
  $DK exec dokandar_kafka /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092 >/dev/null 2>&1 && ok "broker reachable" || bad "broker"
  t=$($DK exec dokandar_kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list 2>/dev/null|grep -cvE '^__|^_')
  [ "$t" -ge 59 ] && ok "$t topics (>=59 contract topics)" || bad "topics ($t < 59)"
  $DK exec dokandar_kafka bash -c '/opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --create --if-not-exists --topic _probe --partitions 1 --replication-factor 1 >/dev/null 2>&1; echo hi | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic _probe >/dev/null 2>&1; /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic _probe --from-beginning --max-messages 1 --timeout-ms 8000 2>/dev/null' | grep -q hi && ok "produce→consume" || bad "produce/consume"
else bad "container not running"; fi

echo "── Schema Registry (Apicurio) ──"
if up dokandar_schema_registry; then
  [ "$(curl -sS -m5 -o /dev/null -w '%{http_code}' http://localhost:${SCHEMA_REGISTRY_PORT}/health/ready)" = 200 ] && ok "/health/ready 200" || bad "health"
  curl -fsS -m5 "http://localhost:${SCHEMA_REGISTRY_PORT}/apis/registry/v2/search/artifacts" >/dev/null 2>&1 && ok "artifacts API" || bad "artifacts API"
else bad "container not running"; fi

echo "── RabbitMQ ──"
if up dokandar_rabbitmq; then
  $DK exec dokandar_rabbitmq rabbitmq-diagnostics -q ping >/dev/null 2>&1 && ok "ping" || bad "ping"
  q=$(curl -sS -m5 -u "$RABBITMQ_DEFAULT_USER:$RABBITMQ_DEFAULT_PASS" "http://localhost:${RABBITMQ_MGMT_PORT}/api/queues/%2F" 2>/dev/null | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))' 2>/dev/null)
  [ "$q" -ge 10 ] 2>/dev/null && ok "$q queues (>=10 contract queues)" || bad "queues ($q < 10)"
else bad "container not running"; fi

echo "── Kafka UI ──"
if up dokandar_kafka_ui; then [ "$(curl -sS -m5 -o /dev/null -w '%{http_code}' http://localhost:${KAFKA_UI_PORT})" = 200 ] && ok "UI 200" || bad "UI"; else skip "kafka-ui"; fi

echo "── OpenSearch (business search) ──"
if up dokandar_opensearch; then
  curl -fsS -m6 "http://localhost:${OPENSEARCH_HTTP_PORT}/_cluster/health" 2>/dev/null | grep -qE 'green|yellow' && ok "cluster green/yellow" || bad "cluster"
  curl -sS -m6 -XPUT "http://localhost:${OPENSEARCH_HTTP_PORT}/dkd-probe" >/dev/null 2>&1
  curl -sS -m6 -XPOST "http://localhost:${OPENSEARCH_HTTP_PORT}/dkd-probe/_doc/1?refresh=true" -H 'Content-Type: application/json' -d '{"k":"v"}' >/dev/null 2>&1
  curl -sS -m6 "http://localhost:${OPENSEARCH_HTTP_PORT}/dkd-probe/_search?q=k:v" 2>/dev/null | grep -q '"value":1' && ok "index→search" || bad "index/search"
  curl -sS -m6 -XDELETE "http://localhost:${OPENSEARCH_HTTP_PORT}/dkd-probe" >/dev/null 2>&1
else skip "opensearch (profile: search)"; fi

echo "── RustFS (object storage) ──"
if up dokandar_rustfs; then
  [ -x "$MC" ] && $MC alias set dkd "http://localhost:${RUSTFS_API_PORT}" "$RUSTFS_ACCESS_KEY" "$RUSTFS_SECRET_KEY" >/dev/null 2>&1
  b=$([ -x "$MC" ] && $MC ls dkd 2>/dev/null | wc -l || echo 0)
  [ "$b" -ge 4 ] 2>/dev/null && ok "$b buckets (>=4)" || bad "buckets ($b)"
else skip "rustfs (profile: storage)"; fi

echo "── Observability (Elastic APM) ──"
if up dokandar_apm_server; then
  [ "$(curl -sS -m6 -o /dev/null -w '%{http_code}' http://localhost:${APM_SERVER_PORT})" = 200 ] && ok "apm-server :8200 200" || bad "apm-server"
else skip "apm-server (profile: observability)"; fi

echo "── Network isolation (search vs observability, ADR-026) ──"
if up dokandar_postgres; then
  if up dokandar_apm_es; then
    $DK exec dokandar_postgres getent hosts apm-elasticsearch >/dev/null 2>&1 && bad "business plane CAN reach observability ES (isolation broken)" || ok "business plane CANNOT reach observability ES"
  else skip "isolation check (observability down)"; fi
fi

echo ""
echo "RESULT: $pass passed, $fail failed"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
