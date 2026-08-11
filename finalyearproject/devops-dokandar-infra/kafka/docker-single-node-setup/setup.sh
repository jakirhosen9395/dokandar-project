#!/usr/bin/env bash
# setup.sh — Kafka lifecycle wrapper. On `up` it auto-fills KAFKA_CLUSTER_ID (random KRaft uuid)
# and KAFKA_EXTERNAL_HOST (this host's public IP) into .env before starting.
set -euo pipefail
cd "$(dirname "$0")"
PUBLIC_IP="${SERVER_IP:-$(grep -sE '^SERVER_IP=' .env | cut -d= -f2)}"; PUBLIC_IP="${PUBLIC_IP:-127.0.0.1}"
step() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()   { printf '   \033[32m✓\033[0m %s\n' "$*"; }
set_env_var(){ local k="$1" v="$2"; { grep -v -E "^${k}=" .env 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } > .env.tmp; mv .env.tmp .env; chmod 600 .env; }
load_env() { [ -f .env ] || bash setup_env.sh; set -a; . ./.env; set +a; }
gen_cluster_id(){ docker run --rm apache/kafka:${KAFKA_VERSION:-4.3.0} /opt/kafka/bin/kafka-storage.sh random-uuid 2>/dev/null | tr -d '\r'; }
wait_healthy() {
  printf '   waiting for healthy'
  for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' dki_kafka 2>/dev/null || true)" = healthy ] && { echo ' ✓'; return 0; }
    printf '.'; sleep 2
  done
  echo; echo '   ! not healthy in time — check: bash setup.sh logs'; exit 1
}
summary() {
  step "Connection details"
  cat <<SUM
  ============ Apache Kafka ${KAFKA_VERSION} (KRaft, docker-single-node) ============
  Bootstrap (local) : 127.0.0.1:${KAFKA_EXTERNAL_PORT}
  Bootstrap (PUBLIC): ${PUBLIC_IP}:${KAFKA_EXTERNAL_PORT}   <- external clients use this
  kafka-ui (browser): http://${PUBLIC_IP}:${KAFKA_UI_PORT}
  Cluster id        : ${KAFKA_CLUSTER_ID}
  Advertised host   : ${KAFKA_EXTERNAL_HOST}
  Data (host)       : ${DATA_ROOT}/kafka   (bind mount — survives 'down -v')
  Try (in box)      : docker compose exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
  ==============================================================
SUM
}
case "${1:-}" in
  up)
    load_env
    step "1/4 Configure KRaft cluster id + advertised host"
    if [ -z "${KAFKA_CLUSTER_ID:-}" ]; then id="$(gen_cluster_id)"; set_env_var KAFKA_CLUSTER_ID "$id"; ok "generated cluster id"; else ok "cluster id reused"; fi
    if [ -z "${KAFKA_EXTERNAL_HOST:-}" ]; then set_env_var KAFKA_EXTERNAL_HOST "$PUBLIC_IP"; ok "advertised host = ${PUBLIC_IP}"; else ok "advertised host reused (${KAFKA_EXTERNAL_HOST})"; fi
    set -a; . ./.env; set +a
    step "2/4 Prepare bind-mount owned by the kafka container user (uid 1000)"
    sudo mkdir -p "${DATA_ROOT}/kafka"; sudo chown -R 1000:1000 "${DATA_ROOT}/kafka"; ok "${DATA_ROOT}/kafka -> uid 1000"
    step "2b/4 docker compose up -d"; docker compose up -d
    step "3/4 health"; wait_healthy
    step "4/4 done"; docker compose ps; summary ;;
  down)   load_env; docker compose down; ok "containers removed — data kept at ${DATA_ROOT}/kafka" ;;
  purge)  load_env; docker compose down -v || true; sudo rm -rf "${DATA_ROOT}/kafka"; ok "containers + data deleted" ;;
  status) load_env; docker compose ps; echo "data: $(sudo du -sh "${DATA_ROOT}/kafka" 2>/dev/null | cut -f1 || echo absent)" ;;
  restart) load_env; docker compose restart; docker compose ps ;;
  logs)   load_env; docker compose logs --tail=80 ;;
  *) echo "Usage: bash setup.sh up|down|purge|status|restart|logs"; exit 2 ;;
esac
