#!/usr/bin/env bash
# DOKANDAR utility — Apache Kafka · Docker Compose single-node (KRaft) + Provectus kafka-ui · wrapper.
# Design ported from the components kafka/ reference, on apache/kafka 4.x. Generates the KRaft CLUSTER_ID,
# sets KAFKA_EXTERNAL_HOST (advertised to off-box clients), brings up the broker + kafka-ui, verifies the
# broker. Data is a HOST bind mount (${DATA_ROOT}/kafka_docker) and SURVIVES `docker compose down -v`.
#   Usage:  bash setup.sh up | down | purge | status | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${KAFKA_VERSION:=4.3.0}"; : "${KAFKA_EXTERNAL_PORT:=9092}"; : "${KAFKA_UI_PORT:=8080}"
DATA_DIR="${DATA_ROOT}/kafka_docker"; CID=dokandar_kafka_docker_single; SVC=kafka

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up | down | purge | status | logs"; }
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true; export "${k}=${v}"
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }
gen_uuid(){ docker run --rm "apache/kafka:${KAFKA_VERSION}" /opt/kafka/bin/kafka-storage.sh random-uuid 2>/dev/null | tr -d '\r' | tail -1; }

resolve_cfg(){
  EXT="${KAFKA_EXTERNAL_HOST:-${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}}"; [ -n "$EXT" ] || EXT=127.0.0.1
  [ -n "${KAFKA_CLUSTER_ID:-}" ] || KAFKA_CLUSTER_ID="$(gen_uuid)"
  set_env_var KAFKA_EXTERNAL_HOST "$EXT"; set_env_var KAFKA_CLUSTER_ID "$KAFKA_CLUSTER_ID"
  set_env_var KAFKA_EXTERNAL_PORT "$KAFKA_EXTERNAL_PORT"; set_env_var KAFKA_UI_PORT "$KAFKA_UI_PORT"; set_env_var KAFKA_VERSION "$KAFKA_VERSION"
}

print_summary(){
  local host="${HOST_IP:-$EXT}"
  step "Connection details (copy the bootstrap into your test env)"
  printf '%s' "$(_c '1;36')"; echo "============ Apache Kafka ${KAFKA_VERSION} (Docker, KRaft) + kafka-ui — connection details ============"; printf '%s' "$(_c 0)"
  cat <<SUM
  Bootstrap (off-box) : ${EXT}:${KAFKA_EXTERNAL_PORT}     (PLAINTEXT_HOST; host/native clients)
  Bootstrap (in-net)  : kafka:29092                       (PLAINTEXT; containers on dokandar_kafka_net)
  Protocol / auth     : PLAINTEXT, no auth (dev — SG-fenced)
  Cluster id          : ${KAFKA_CLUSTER_ID}
  Browser UI          : http://${host}:${KAFKA_UI_PORT}   (Provectus kafka-ui)
  Test from afar      : bash ../test.sh "${EXT}:${KAFKA_EXTERNAL_PORT}"
  Data (host)         : ${DATA_DIR}   (bind mount — survives 'down -v')
  Saved to            : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "==================================================================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  resolve_cfg
  step "1/3  Configuration"; ok "external=${EXT}:${KAFKA_EXTERNAL_PORT}  ui=:${KAFKA_UI_PORT}  cluster-id=${KAFKA_CLUSTER_ID}  image=apache/kafka:${KAFKA_VERSION}"
  step "2/3  Bind-mount data dir + docker compose up -d (broker + kafka-ui)"
  sudo mkdir -p "$DATA_DIR"; sudo chown -R 1000:1000 "$DATA_DIR"   # apache/kafka runs as uid 1000
  docker compose up -d
  printf '   waiting for broker healthy'
  for _ in $(seq 1 40); do [ "$(docker inspect -f '{{.State.Health.Status}}' "$CID" 2>/dev/null || echo)" = healthy ] && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  step "3/3  Verify broker + UI"
  docker compose exec -T "$SVC" /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092 >/dev/null 2>&1 && ok "broker reachable" || warn "broker not answering — see 'bash setup.sh logs'"
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${KAFKA_UI_PORT}/" 2>/dev/null)" != 000 ] && ok "kafka-ui serving on :${KAFKA_UI_PORT}" || warn "kafka-ui still starting"
  docker compose ps
  print_summary
}

do_down(){ docker compose down; echo "Containers removed. DATA PRESERVED at ${DATA_DIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$DATA_DIR"; echo "Full wipe: containers + ${DATA_DIR} removed."; }
do_status(){ docker compose ps || true; echo "data (host): ${DATA_DIR} ($(sudo du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"; }
do_logs(){ docker compose logs --tail=80 -f; }

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  up|install)     do_up ;;
  down|uninstall) do_down ;;
  purge)          do_purge ;;
  status)         do_status ;;
  logs)           do_logs ;;
  *) usage; exit 2 ;;
esac
