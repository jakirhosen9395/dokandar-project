#!/usr/bin/env bash
# setup.sh — lifecycle wrapper (up | down | purge | status | restart | logs). See ../README.md.
set -euo pipefail
cd "$(dirname "$0")"
step() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()   { printf '   \033[32m✓\033[0m %s\n' "$*"; }
load_env() { [ -f .env ] || bash setup_env.sh; set -a; . ./.env; set +a; }
wait_healthy() {
  printf '   waiting for healthy'
  for _ in $(seq 1 45); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' dki_timescaledb 2>/dev/null || true)" = healthy ] && { echo ' ✓'; return 0; }
    printf '.'; sleep 2
  done
  echo; echo '   ! not healthy in time — check: bash setup.sh logs'; exit 1
}
summary() {
  PUBLIC_IP="${SERVER_IP:-$(grep -sE '^SERVER_IP=' .env | cut -d= -f2)}"; PUBLIC_IP="${PUBLIC_IP:-127.0.0.1}"
  step "Connection details (password lives in .env, chmod 600)"
  cat <<SUM
  ============ TimescaleDB ${TSDB_VERSION} (docker-single-node) ============
  Host (local)   : 127.0.0.1:${TSDB_PORT}
  Host (PUBLIC)  : ${PUBLIC_IP}:${TSDB_PORT}
  User / DB      : ${TSDB_USER} / ${TSDB_DB}
  Password       : ${TSDB_PASSWORD}
  Connection URL : postgresql://${TSDB_USER}:${TSDB_PASSWORD}@${PUBLIC_IP}:${TSDB_PORT}/${TSDB_DB}
  Data (host)    : ${DATA_ROOT}/timescaledb   (bind mount — survives 'down -v')
  ==============================================================
SUM
}
case "${1:-}" in
  up)     load_env; step "docker compose up -d"; docker compose up -d
          step "health"; wait_healthy; docker compose ps; summary ;;
  down)   load_env; docker compose down; ok "container removed — data kept" ;;
  purge)  load_env; docker compose down -v || true; sudo rm -rf "${DATA_ROOT}/timescaledb"; ok "container + data deleted" ;;
  status) load_env; docker compose ps ;;
  restart) load_env; docker compose restart; docker compose ps ;;
  logs)   load_env; docker compose logs --tail=80 ;;
  *) echo "Usage: bash setup.sh up|down|purge|status|restart|logs"; exit 2 ;;
esac
