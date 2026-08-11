#!/usr/bin/env bash
# setup.sh — lifecycle wrapper for the Elastic APM stack (ES + Kibana + APM server).
#   up      start ES first, set the kibana_system password (one-shot bootstrap),
#           then let Kibana + APM server come up; print credentials + URLs
#   down    stop + remove containers (DATA KEPT on the host)
#   purge   remove containers AND delete the data directory (irreversible)
#   status  compose ps + data size
#   logs    follow all three containers' logs
set -euo pipefail
cd "$(dirname "$0")"

step() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()   { printf '   \033[32m✓\033[0m %s\n' "$*"; }
load_env() { [ -f .env ] || bash setup_env.sh; set -a; . ./.env; set +a; }
PUBIP() { echo "${SERVER_IP:-$(grep -sE '^SERVER_IP=' .env | cut -d= -f2)}"; }

wait_ct() { # wait_ct <container> <tries>
  printf '   waiting for %s' "$1"
  for _ in $(seq 1 "$2"); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null || true)" = healthy ] \
      && { echo ' ✓'; return 0; }
    printf '.'; sleep 3
  done
  echo; echo "   ! $1 not healthy in time — check: bash setup.sh logs"; exit 1
}

summary() {
  step "Credentials + URLs (secrets live in .env, chmod 600)"
  cat <<SUM
  ============ Elastic APM stack ${ELASTIC_VERSION} (docker-single-node) ============
  Kibana (BROWSER): http://$(PUBIP):${KIBANA_PORT}     login: elastic / ${ELASTIC_PASSWORD}
  Elasticsearch   : http://$(PUBIP):${ES_PORT}          (basic auth: elastic / <same>)
  APM intake      : http://$(PUBIP):${APM_PORT}         (agents authenticate with the token)
  APM secret token: ${APM_SECRET_TOKEN}
  Point an agent  : ELASTIC_APM_SERVER_URL=http://$(PUBIP):${APM_PORT}
                    ELASTIC_APM_SECRET_TOKEN=<token above>
  Data (host)     : ${DATA_ROOT}/elastic-apm   (bind mount — survives 'down -v')
  ==================================================================
SUM
}

case "${1:-}" in
  up)
    load_env
    step "1/5 Prepare bind mount owned by the elasticsearch user (uid 1000)"
    sudo mkdir -p "${DATA_ROOT}/elastic-apm/elasticsearch"
    sudo chown -R 1000:1000 "${DATA_ROOT}/elastic-apm"; ok "${DATA_ROOT}/elastic-apm -> uid 1000"
    sudo sysctl -w vm.max_map_count=262144 >/dev/null 2>&1 || true; ok "vm.max_map_count=262144"
    step "2/5 Start elasticsearch"; docker compose up -d elasticsearch; wait_ct dki_apm_es 40
    step "3/5 One-shot bootstrap: set the kibana_system user's password"
    docker compose exec -T elasticsearch curl -fs -u "elastic:${ELASTIC_PASSWORD}" \
      -X POST http://localhost:9200/_security/user/kibana_system/_password \
      -H 'Content-Type: application/json' -d "{\"password\":\"${KIBANA_PASSWORD}\"}" >/dev/null \
      && ok "kibana_system password set" || { echo '   ! failed to set kibana_system password'; exit 1; }
    step "4/5 Start kibana + apm-server"; docker compose up -d
    wait_ct dki_apm_kibana 40; wait_ct dki_apm_server 20
    step "5/5 done"; docker compose ps; summary ;;
  down)   load_env; docker compose down; ok "containers removed — data kept at ${DATA_ROOT}/elastic-apm" ;;
  purge)  load_env; docker compose down -v || true; sudo rm -rf "${DATA_ROOT}/elastic-apm"; ok "containers + data deleted" ;;
  status) load_env; docker compose ps; echo "data: $(sudo du -sh "${DATA_ROOT}/elastic-apm" 2>/dev/null | cut -f1 || echo absent)" ;;
  restart) load_env; docker compose restart; docker compose ps ;;
  logs)   load_env; docker compose logs --tail=60 ;;
  *) echo "Usage: bash setup.sh up|down|purge|status|restart|logs"; exit 2 ;;
esac
