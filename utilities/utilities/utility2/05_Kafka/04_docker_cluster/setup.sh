#!/usr/bin/env bash
# DOKANDAR utility — Apache Kafka 4.3 · Docker Compose HA cluster (KRaft, 3 broker+controller) · wrapper.
# 3 nodes, static quorum [1,2,3], host networking + per-node advertised host:port so the cluster is
# reachable locally AND cross-host. PLAINTEXT (dev). Per-node data are HOST bind mounts (survive down -v).
#   Usage:  bash setup.sh up | down | purge | status | acceptance | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || { echo "No .env here — run:  cp .env.example .env"; exit 2; }
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${KAFKA_VERSION:=4.3.0}"; : "${KAFKA_UI_PORT:=8080}"
DATA_DIR="${DATA_ROOT}/kafka_cluster"; PORTS="9092 9094 9096"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up | down | purge | status | acceptance | logs"; }
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true; export "${k}=${v}"
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }
gen_uuid(){ docker run --rm "apache/kafka:${KAFKA_VERSION}" /opt/kafka/bin/kafka-storage.sh random-uuid 2>/dev/null | tr -d '\r' | tail -1; }
# kafka CLI inside node 1. $1=tool, rest=args
kc(){ local t="$1"; shift; docker compose exec -T kafka-1 /opt/kafka/bin/"$t" "$@" 2>/dev/null; }

resolve_cfg(){
  ADV="${KAFKA_ADVERTISED_HOST:-${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}}"; [ -n "$ADV" ] || ADV=127.0.0.1
  [ -n "${KAFKA_CLUSTER_ID:-}" ] || KAFKA_CLUSTER_ID="$(gen_uuid)"
  set_env_var KAFKA_ADVERTISED_HOST "$ADV"; set_env_var KAFKA_CLUSTER_ID "$KAFKA_CLUSTER_ID"
  set_env_var KAFKA_EXTERNAL_PORT 9092; set_env_var KAFKA_VERSION "$KAFKA_VERSION"   # 9092 = node 1 (test.sh bootstrap)
  set_env_var KAFKA_UI_PORT "$KAFKA_UI_PORT"
}

print_summary(){
  step "Connection details"
  printf '%s' "$(_c '1;36')"; echo "========= Apache Kafka ${KAFKA_VERSION} HA cluster (Docker, KRaft) — connection details ========="; printf '%s' "$(_c 0)"
  cat <<SUM
  Bootstrap        : ${ADV}:9092,${ADV}:9094,${ADV}:9096   (3 brokers; any is a valid bootstrap)
  Topology         : 3 combined broker+controller nodes, static quorum [1,2,3]
  Protocol / auth  : PLAINTEXT, no auth (dev)
  Cluster id       : ${KAFKA_CLUSTER_ID}
  Test (cluster)   : bash ../test.sh "${ADV}:9092"
  Verify HA        : bash setup.sh acceptance
  Data (host)      : ${DATA_DIR}/{n1,n2,n3}   (bind mounts — survive 'down -v')
  Browser UI       : http://${ADV}:${KAFKA_UI_PORT}   (Provectus kafka-ui — sees all 3 brokers)
  Saved to         : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "==============================================================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  resolve_cfg
  step "1/4  Configuration"; ok "3 nodes data-ports=9092/9094/9096  advertised=${ADV}  cluster-id=${KAFKA_CLUSTER_ID}"
  step "2/4  Per-node data dirs + docker compose up (3 nodes, host network)"
  for n in 1 2 3; do sudo mkdir -p "$DATA_DIR/n$n"; done; sudo chown -R 1000:1000 "$DATA_DIR"   # apache/kafka uid 1000
  docker compose up -d
  printf '   waiting for 3 brokers'
  for _ in $(seq 1 40); do
    local n=0; for p in $PORTS; do docker compose exec -T kafka-1 /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server "${ADV}:$p" >/dev/null 2>&1 && n=$((n+1)); done
    [ "$n" = 3 ] && { echo ' ✓'; break; }; printf '.'; sleep 3
  done
  step "3/4  Cluster state"
  local nb; nb="$(kc kafka-broker-api-versions.sh --bootstrap-server "${ADV}:9092" 2>/dev/null | grep -c 'id:')"
  ok "brokers in cluster: ${nb:-?}"
  step "4/4  Done"
  docker compose ps
  print_summary
}

do_acceptance(){
  : "${KAFKA_ADVERTISED_HOST:?}"; local ADV="$KAFKA_ADVERTISED_HOST" T="ha_check_$$"
  echo "== (1) broker count == 3 =="
  echo "   brokers: $(kc kafka-broker-api-versions.sh --bootstrap-server "${ADV}:9092" | grep -c 'id:')"
  echo "== (2) RF3 topic -> ISR size 3 =="
  kc kafka-topics.sh --bootstrap-server "${ADV}:9092" --create --topic "$T" --partitions 1 --replication-factor 3 >/dev/null 2>&1
  local isr; isr="$(kc kafka-topics.sh --bootstrap-server "${ADV}:9092" --describe --topic "$T" | grep -oE 'Isr: [0-9,]+' | head -1)"
  echo "   $isr"; echo "$isr" | grep -qE 'Isr: [0-9]+,[0-9]+,[0-9]+' && echo "OK: ISR size 3" || echo "FAIL: ISR not 3"
  echo "== (3) produce via node 1, consume via node 2 =="
  printf 'ha-msg\n' | docker compose exec -T kafka-1 /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server "${ADV}:9092" --topic "$T" >/dev/null 2>&1
  local got; got="$(docker compose exec -T kafka-1 /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server "${ADV}:9094" --topic "$T" --from-beginning --max-messages 1 --timeout-ms 15000 2>/dev/null | tr -d '\r' | head -1)"
  [ "$got" = ha-msg ] && echo "OK: message read via node 2 (replicated)" || echo "FAIL: cross-node read"
  kc kafka-topics.sh --bootstrap-server "${ADV}:9092" --delete --topic "$T" >/dev/null 2>&1 || true
}

do_down(){ docker compose down; echo "Containers removed. DATA PRESERVED at ${DATA_DIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$DATA_DIR"; echo "Full wipe: containers + ${DATA_DIR} removed."; }
do_status(){ docker compose ps || true; echo "data: ${DATA_DIR} ($(sudo du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"; }
do_logs(){ docker compose logs --tail=80 -f; }

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  up|install)     do_up ;;
  down|uninstall) do_down ;;
  purge)          do_purge ;;
  status)         do_status ;;
  acceptance)     do_acceptance ;;
  logs)           do_logs ;;
  *) usage; exit 2 ;;
esac
