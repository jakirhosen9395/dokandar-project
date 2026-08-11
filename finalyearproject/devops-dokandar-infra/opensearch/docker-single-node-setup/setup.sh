#!/usr/bin/env bash
# setup.sh — OpenSearch lifecycle wrapper. Pre-owns the bind mount for the container user
# (uid 1000) and raises the host's vm.max_map_count (search engines require it).
set -euo pipefail
cd "$(dirname "$0")"
PUBLIC_IP="${SERVER_IP:-$(grep -sE '^SERVER_IP=' .env | cut -d= -f2)}"; PUBLIC_IP="${PUBLIC_IP:-127.0.0.1}"
step() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()   { printf '   \033[32m✓\033[0m %s\n' "$*"; }
load_env() { [ -f .env ] || bash setup_env.sh; set -a; . ./.env; set +a; }
wait_healthy() {
  printf '   waiting for healthy'
  for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' dki_opensearch 2>/dev/null || true)" = healthy ] && { echo ' ✓'; return 0; }
    printf '.'; sleep 2
  done
  echo; echo '   ! not healthy in time — check: bash setup.sh logs'; exit 1
}
summary() {
  step "Connection details"
  cat <<SUM
  ============ OpenSearch ${OPENSEARCH_VERSION} (docker-single-node, security OFF) ============
  REST (local)   : http://127.0.0.1:${OPENSEARCH_PORT}
  REST (PUBLIC)  : http://${PUBLIC_IP}:${OPENSEARCH_PORT}
  Health (remote): curl http://${PUBLIC_IP}:${OPENSEARCH_PORT}/_cluster/health?pretty
  Data (host)    : ${DATA_ROOT}/opensearch   (bind mount — survives 'down -v')
  Note           : security plugin is OFF (no auth) — matches the local DOKANDAR config.
  ==============================================================
SUM
}
case "${1:-}" in
  up)
    load_env
    step "1/4 Prepare bind mount + host kernel setting"
    sudo mkdir -p "${DATA_ROOT}/opensearch"; sudo chown -R 1000:1000 "${DATA_ROOT}/opensearch"; ok "data dir -> uid 1000"
    sudo sysctl -w vm.max_map_count=262144 >/dev/null 2>&1 && ok "vm.max_map_count=262144" || ok "vm.max_map_count already set"
    step "2/4 docker compose up -d"; docker compose up -d
    step "3/4 health"; wait_healthy
    step "4/4 done"; docker compose ps; summary ;;
  down)   load_env; docker compose down; ok "container removed — data kept at ${DATA_ROOT}/opensearch" ;;
  purge)  load_env; docker compose down -v || true; sudo rm -rf "${DATA_ROOT}/opensearch"; ok "container + data deleted" ;;
  status) load_env; docker compose ps; echo "data: $(sudo du -sh "${DATA_ROOT}/opensearch" 2>/dev/null | cut -f1 || echo absent)" ;;
  restart) load_env; docker compose restart; docker compose ps ;;
  logs)   load_env; docker compose logs --tail=80 ;;
  *) echo "Usage: bash setup.sh up|down|purge|status|restart|logs"; exit 2 ;;
esac
