#!/usr/bin/env bash
# setup.sh — lifecycle wrapper (up | down | purge | status | restart | logs). See ../README.md.
set -euo pipefail
cd "$(dirname "$0")"
PUBLIC_IP="${SERVER_IP:-$(grep -sE '^SERVER_IP=' .env | cut -d= -f2)}"; PUBLIC_IP="${PUBLIC_IP:-127.0.0.1}"
step() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()   { printf '   \033[32m✓\033[0m %s\n' "$*"; }
load_env() { [ -f .env ] || bash setup_env.sh; set -a; . ./.env; set +a; }
wait_healthy() {
  printf '   waiting for healthy'
  for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' dki_rabbitmq 2>/dev/null || true)" = healthy ] \
      && { echo ' ✓'; return 0; }
    printf '.'; sleep 2
  done
  echo; echo '   ! not healthy in time — check: bash setup.sh logs'; exit 1
}
summary() {
  step "Connection details (secrets live in .env, chmod 600)"
  cat <<SUM
  ============ RabbitMQ (docker-single-node, management UI) ============
  AMQP (local)   : 127.0.0.1:${RABBITMQ_AMQP_PORT}
  AMQP (PUBLIC)  : ${PUBLIC_IP}:${RABBITMQ_AMQP_PORT}
  Web UI (PUBLIC): http://${PUBLIC_IP}:${RABBITMQ_MGMT_PORT}   <- open in your browser
  User           : ${RABBITMQ_USER}
  Password       : ${RABBITMQ_PASSWORD}
  Connection URL : amqp://${RABBITMQ_USER}:${RABBITMQ_PASSWORD}@${PUBLIC_IP}:${RABBITMQ_AMQP_PORT}/
  Data (host)    : ${DATA_ROOT}/rabbitmq   (bind mount — survives 'down -v')
  ==============================================================
SUM
}
case "${1:-}" in
  up)     load_env; step "1/3 docker compose up -d"; docker compose up -d
          step "2/3 health"; wait_healthy
          step "3/3 done"; docker compose ps; summary ;;
  down)   load_env; docker compose down; ok "container removed — data kept at ${DATA_ROOT}/rabbitmq" ;;
  purge)  load_env; docker compose down -v || true; sudo rm -rf "${DATA_ROOT}/rabbitmq"; ok "container + data deleted" ;;
  status) load_env; docker compose ps; echo "data: $(sudo du -sh "${DATA_ROOT}/rabbitmq" 2>/dev/null | cut -f1 || echo absent)" ;;
  restart) load_env; docker compose restart; docker compose ps ;;
  logs)   load_env; docker compose logs --tail=80 ;;
  *) echo "Usage: bash setup.sh up|down|purge|status|restart|logs"; exit 2 ;;
esac
