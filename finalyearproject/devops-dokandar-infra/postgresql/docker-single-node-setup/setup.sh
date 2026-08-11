#!/usr/bin/env bash
# setup.sh — lifecycle wrapper for the PostgreSQL docker-single-node variant.
#   up      start (creates .env via setup_env.sh if needed), wait healthy,
#           PROVISION/REPAIR the multi-database list, print credentials
#   down    stop + remove the container (DATA KEPT on the host)
#   purge   remove the container AND delete the data directory (irreversible)
#   status  compose ps + data-dir size
#   logs    follow the container logs
#
# THE CONSOLIDATION LESSON: one postgres container serves MANY databases.
# `up` is idempotent — add a name to DKD_DATABASES in .env and re-run it to get
# a new database + role + generated password WITHOUT any new container.
set -euo pipefail
cd "$(dirname "$0")"

step() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()   { printf '   \033[32m✓\033[0m %s\n' "$*"; }

gen_password() { { command -v openssl >/dev/null && openssl rand -base64 48 || head -c 256 /dev/urandom; } \
  | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24; }
set_env_var(){ local k="$1" v="$2"; { grep -v -E "^${k}=" .env 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } > .env.tmp; mv .env.tmp .env; chmod 600 .env; }
load_env() { [ -f .env ] || bash setup_env.sh; set -a; . ./.env; set +a; }

wait_healthy() {
  printf '   waiting for healthy'
  for _ in $(seq 1 45); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' dki_postgres 2>/dev/null || true)" = healthy ] \
      && { echo ' ✓'; return 0; }
    printf '.'; sleep 2
  done
  echo; echo '   ! not healthy in time — check: bash setup.sh logs'; exit 1
}

# Idempotent multi-DB provisioning: for each name in DKD_DATABASES ensure the
# role + database exist and the role's password matches DKD_PASSWORD_<NAME>
# (generated here on first sight). Safe to re-run any time.
provision_databases() {
  IFS=',' read -ra DBS <<< "${DKD_DATABASES:-}"
  for db in "${DBS[@]}"; do
    db="$(echo "$db" | tr -d '[:space:]')"; [ -z "$db" ] && continue
    local var="DKD_PASSWORD_$(echo "$db" | tr '[:lower:]' '[:upper:]')"
    local pw="${!var:-}"
    if [ -z "$pw" ]; then pw="$(gen_password)"; set_env_var "$var" "$pw"; ok "generated password for role '$db'"; fi
    docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres -q <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$db') THEN CREATE ROLE "$db" LOGIN; END IF;
END \$\$;
ALTER ROLE "$db" WITH LOGIN PASSWORD '$pw';
SELECT format('CREATE DATABASE %I OWNER %I', '$db', '$db')
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$db') \gexec
SQL
    ok "database '$db' ready (role '$db')"
  done
}

summary() {
  set -a; . ./.env; set +a
  step "Connection details (passwords live in .env, chmod 600)"
  echo "  ============ PostgreSQL ${POSTGRES_VERSION} — ONE container, MANY databases ============"
  echo "  Host (local)   : 127.0.0.1:${POSTGRES_PORT}"
  echo "  Host (PUBLIC)  : ${SERVER_IP}:${POSTGRES_PORT}"
  echo "  Superuser      : ${POSTGRES_USER}  (password: ${POSTGRES_PASSWORD})"
  IFS=',' read -ra DBS <<< "${DKD_DATABASES:-}"
  for db in "${DBS[@]}"; do
    db="$(echo "$db" | tr -d '[:space:]')"; [ -z "$db" ] && continue
    local var="DKD_PASSWORD_$(echo "$db" | tr '[:lower:]' '[:upper:]')"
    echo "  Database       : postgresql://${db}:${!var:-<run up>}@${SERVER_IP}:${POSTGRES_PORT}/${db}"
  done
  echo "  Add a database : edit DKD_DATABASES in .env, re-run 'bash setup.sh up' (no new container)"
  echo "  Data (host)    : ${DATA_ROOT}/postgresql   (bind mount — survives 'down -v')"
  echo "  =============================================================================="
}

case "${1:-}" in
  up)
    load_env
    step "1/4 docker compose up -d"; docker compose up -d
    step "2/4 health"; wait_healthy
    step "3/4 provision the multi-database list (idempotent)"; provision_databases
    step "4/4 done"; docker compose ps; summary ;;
  down)   load_env; docker compose down; ok "container removed — data kept at ${DATA_ROOT}/postgresql" ;;
  purge)  load_env; docker compose down -v || true; sudo rm -rf "${DATA_ROOT}/postgresql"; ok "container + data deleted" ;;
  status) load_env; docker compose ps; echo "data: $(sudo du -sh "${DATA_ROOT}/postgresql" 2>/dev/null | cut -f1 || echo absent)" ;;
  restart) load_env; docker compose restart; docker compose ps ;;
  logs)   load_env; docker compose logs --tail=80 ;;
  *) echo "Usage: bash setup.sh up|down|purge|status|restart|logs"; exit 2 ;;
esac
