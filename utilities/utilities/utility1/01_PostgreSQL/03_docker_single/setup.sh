#!/usr/bin/env bash
# DOKANDAR utility — PostgreSQL 18 · Docker Compose single-node · lifecycle wrapper.
# Auto-generates a COMPLEX password when none is set; accepts --user / --db / --password / --gen-password.
# Data is a HOST bind mount (${DATA_ROOT}/postgresql_docker) and SURVIVES `docker compose down -v`;
# only `setup.sh purge` deletes it. Prints credentials at the end.
#   Usage:  bash setup.sh up [--user U] [--db D] [--password P | --gen-password]
#           bash setup.sh down | purge | status | logs        (aliases: install=up, uninstall=down)
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || { echo "No .env here — run:  cp .env.example .env"; exit 2; }
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; DATA_DIR="${DATA_ROOT}/postgresql_docker"; CID=dokandar_pg_docker_single; SVC=postgres

# ---- pretty step output ----
_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up [--user U] [--db D] [--password P | --gen-password] | down | purge | status | logs"; }

# ---- credential helpers ----
gen_password(){ printf '%s' "$( set +o pipefail
  { command -v openssl >/dev/null 2>&1 && openssl rand -base64 48 || head -c 256 /dev/urandom; } \
  | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24 )"; }
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }
sqlq(){ printf '%s' "${1//\'/\'\'}"; }

USER_ARG=""; DB_ARG=""; PASS_ARG=""; GEN=0
parse_args(){ while [ $# -gt 0 ]; do case "$1" in
    --user) USER_ARG="${2:?}"; shift 2;;  --user=*) USER_ARG="${1#*=}"; shift;;
    --db) DB_ARG="${2:?}"; shift 2;;       --db=*) DB_ARG="${1#*=}"; shift;;
    --password) PASS_ARG="${2:?}"; shift 2;; --password=*) PASS_ARG="${1#*=}"; shift;;
    --gen-password) GEN=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1"; usage; exit 2;;
  esac; done; }

resolve_creds(){
  local OLD_USER="${POSTGRES_USER:-postgres}"
  # Docker cannot rename the superuser on existing data — warn and keep the original.
  if [ -n "$USER_ARG" ] && [ "$USER_ARG" != "$OLD_USER" ] && sudo test -d "${DATA_DIR}/pgdata" 2>/dev/null; then
    warn "existing cluster superuser is '${OLD_USER}' — Docker cannot rename it; ignoring --user '${USER_ARG}'"; USER_ARG=""
  fi
  USER_="${USER_ARG:-$OLD_USER}"; DB_="${DB_ARG:-${POSTGRES_DB:-}}"; PORT_="${POSTGRES_PORT:-5432}"
  if   [ -n "$PASS_ARG" ];              then PASS_="$PASS_ARG";          PW_SRC="provided (--password)"
  elif [ "$GEN" = 1 ];                  then PASS_="$(gen_password)";    PW_SRC="auto-generated (--gen-password)"
  elif [ -n "${POSTGRES_PASSWORD:-}" ]; then PASS_="$POSTGRES_PASSWORD"; PW_SRC="reused from .env"
  else                                       PASS_="$(gen_password)";    PW_SRC="auto-generated (.env was empty)"
  fi
  # write BEFORE `up` so the image's first-init uses it; ALTER ROLE below enforces it on existing data.
  set_env_var POSTGRES_USER "$USER_"; [ -n "$DB_" ] && set_env_var POSTGRES_DB "$DB_"; set_env_var POSTGRES_PASSWORD "$PASS_"
}

print_summary(){
  local db="${DB_:-postgres}"
  step "Connection details (password shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "============ PostgreSQL 18 (Docker) — connection details ============"; printf '%s' "$(_c 0)"
  cat <<SUM
  Host / port    : 127.0.0.1 / ${PORT_}   (container 5432)
  User           : ${USER_}
  Password       : ${PASS_}   [${PW_SRC}]
  Database       : ${db}
  Connection URL : postgresql://${USER_}:${PASS_}@127.0.0.1:${PORT_}/${db}
  psql (host)    : PGPASSWORD='${PASS_}' psql -h 127.0.0.1 -p ${PORT_} -U ${USER_} -d ${db}
  psql (exec)    : docker compose exec ${SVC} psql -U ${USER_} -d ${db}
  Data (host)    : ${DATA_DIR}   (bind mount — survives 'down -v')
  Browser UI     : none
  Saved to       : ${ENV_FILE} (chmod 600, gitignored) — the password persists there
SUM
  printf '%s' "$(_c '1;36')"; echo "===================================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  resolve_creds
  step "1/4  Configuration"; ok "user=${USER_}  db=${DB_:-<none>}  host-port=${PORT_}  password=${PW_SRC}"
  step "2/4  Bind-mount data dir"; sudo mkdir -p "$DATA_DIR"; ok "$DATA_DIR"
  step "3/4  docker compose up -d --build"; docker compose up -d --build
  printf '   waiting for healthy'
  for _ in $(seq 1 45); do [ "$(docker inspect -f '{{.State.Health.Status}}' "$CID" 2>/dev/null || echo)" = healthy ] && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  step "4/4  Enforcing credentials + optional database (local trust inside the container)"
  local PWS; PWS="$(sqlq "$PASS_")"
  if docker compose exec -T "$SVC" psql -v ON_ERROR_STOP=1 -U "$USER_" -d postgres -c "ALTER ROLE \"${USER_}\" WITH LOGIN PASSWORD '${PWS}';" >/dev/null 2>&1; then
    ok "password set on role '${USER_}'"
  else warn "could not ALTER ROLE '${USER_}' — see 'bash setup.sh logs'"; fi
  if [ -n "$DB_" ]; then
    if docker compose exec -T "$SVC" psql -U "$USER_" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_}'" 2>/dev/null | grep -q 1; then ok "database '${DB_}' already present"
    else docker compose exec -T "$SVC" createdb -U "$USER_" -O "$USER_" "$DB_" >/dev/null 2>&1 && ok "database '${DB_}' created" || warn "could not create db '${DB_}'"; fi
  fi
  docker compose ps
  print_summary
}

do_down(){ docker compose down; echo "Container removed. DATA PRESERVED at ${DATA_DIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$DATA_DIR"; echo "Full wipe: container + ${DATA_DIR} removed."; }
do_status(){
  docker compose ps || true
  if command -v pg_isready >/dev/null 2>&1; then pg_isready -h 127.0.0.1 -p "${POSTGRES_PORT:-5432}" && echo "pg_isready: OK" || echo "pg_isready: DOWN"; fi
  echo "user/db    : ${POSTGRES_USER:-postgres} / ${POSTGRES_DB:-postgres}   (password in ${ENV_FILE})"
  echo "data (host): ${DATA_DIR} ($(sudo du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"
}
do_logs(){ docker compose logs --tail=80 -f; }

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  up|install)     parse_args "$@"; do_up ;;
  down|uninstall) do_down ;;
  purge)          do_purge ;;
  status)         do_status ;;
  logs)           do_logs ;;
  *) usage; exit 2 ;;
esac
