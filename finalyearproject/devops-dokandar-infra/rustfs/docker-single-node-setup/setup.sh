#!/usr/bin/env bash
# setup.sh — lifecycle wrapper (up | down | purge | status | restart | logs). See ../README.md.
set -euo pipefail
cd "$(dirname "$0")"
step() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()   { printf '   \033[32m✓\033[0m %s\n' "$*"; }
load_env() { [ -f .env ] || bash setup_env.sh; set -a; . ./.env; set +a; }
wait_healthy() {
  printf '   waiting for healthy'
  for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' dki_rustfs 2>/dev/null || true)" = healthy ] && { echo ' ✓'; return 0; }
    printf '.'; sleep 3
  done
  echo; echo '   ! not healthy in time — check: bash setup.sh logs'; exit 1
}
summary() {
  PUBLIC_IP="${SERVER_IP:-$(grep -sE '^SERVER_IP=' .env | cut -d= -f2)}"; PUBLIC_IP="${PUBLIC_IP:-127.0.0.1}"
  step "Connection details (secrets live in .env, chmod 600)"
  cat <<SUM
  ============ RustFS ${RUSTFS_VERSION} (docker-single-node) ============
  S3 API (local)  : http://127.0.0.1:${RUSTFS_API_PORT}
  S3 API (PUBLIC) : http://${PUBLIC_IP}:${RUSTFS_API_PORT}
  Console (PUBLIC): http://${PUBLIC_IP}:${RUSTFS_CONSOLE_PORT}/rustfs/console/index.html   <- browser
  Access key      : ${RUSTFS_ACCESS_KEY}
  Secret key      : ${RUSTFS_SECRET_KEY}
  mc alias        : MC_HOST_rfs=http://${RUSTFS_ACCESS_KEY}:${RUSTFS_SECRET_KEY}@${PUBLIC_IP}:${RUSTFS_API_PORT}
  Data (host)     : ${DATA_ROOT}/rustfs   (bind mounts — survive 'down -v')
  ==============================================================
SUM
}
case "${1:-}" in
  up)     load_env
          step "prepare bind mounts for the container user (uid 10001)"
          sudo mkdir -p "${DATA_ROOT:-/data/dki}/rustfs/data" "${DATA_ROOT:-/data/dki}/rustfs/logs"
          sudo chown -R 10001:10001 "${DATA_ROOT:-/data/dki}/rustfs"; ok "chowned for uid 10001"
          step "docker compose up -d"; docker compose up -d
          step "health"; wait_healthy
          docker compose ps; summary ;;
  down)   load_env; docker compose down; ok "container removed — data kept at ${DATA_ROOT:-/data/dki}/rustfs" ;;
  purge)  load_env; docker compose down -v || true; sudo rm -rf "${DATA_ROOT:-/data/dki}/rustfs"; ok "container + data deleted" ;;
  status) load_env; docker compose ps ;;
  restart) load_env; docker compose restart; docker compose ps ;;
  logs)   load_env; docker compose logs --tail=80 ;;
  *) echo "Usage: bash setup.sh up|down|purge|status|restart|logs"; exit 2 ;;
esac
