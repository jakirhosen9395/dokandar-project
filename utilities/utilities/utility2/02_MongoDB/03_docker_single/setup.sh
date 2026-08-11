#!/usr/bin/env bash
# DOKANDAR utility — MongoDB 7.0 · Docker Compose single-node · lifecycle wrapper.
# Auto-generates a COMPLEX password when none is set; accepts --user / --db / --password / --gen-password.
# Data is a HOST bind mount (${DATA_ROOT}/mongodb_docker) and SURVIVES `docker compose down -v`;
# only `setup.sh purge` deletes it. Prints credentials at the end.
#   Usage:  bash setup.sh up [--user U] [--db D] [--password P | --gen-password]
#           bash setup.sh down | purge | status | logs        (aliases: install=up, uninstall=down)
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || { echo "No .env here — run:  cp .env.example .env"; exit 2; }
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${MONGO_VERSION:=7.0}"
DATA_DIR="${DATA_ROOT}/mongodb_docker"; CID=dokandar_mongo_docker_single; SVC=mongo

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
  export "${k}=${v}"   # also update THIS shell's env, else an exported-empty value shadows .env for compose
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }
jsq(){ printf '%s' "${1//\'/\\\'}"; }

USER_ARG=""; DB_ARG=""; PASS_ARG=""; GEN=0
parse_args(){ while [ $# -gt 0 ]; do case "$1" in
    --user) USER_ARG="${2:?}"; shift 2;;  --user=*) USER_ARG="${1#*=}"; shift;;
    --db) DB_ARG="${2:?}"; shift 2;;       --db=*) DB_ARG="${1#*=}"; shift;;
    --password) PASS_ARG="${2:?}"; shift 2;; --password=*) PASS_ARG="${1#*=}"; shift;;
    --gen-password) GEN=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1"; usage; exit 2;;
  esac; done; }

OLD_PASS=""
resolve_creds(){
  OLD_PASS="${MONGO_ROOT_PASSWORD:-}"
  local OLD_USER="${MONGO_ROOT_USER:-dokandar}"
  # MongoDB cannot rename the existing root user on existing data — warn and keep the original.
  if [ -n "$USER_ARG" ] && [ "$USER_ARG" != "$OLD_USER" ] && sudo test -d "${DATA_DIR}/db" 2>/dev/null; then
    warn "existing root user is '${OLD_USER}' — cannot rename on existing data; ignoring --user '${USER_ARG}'"; USER_ARG=""
  fi
  USER_="${USER_ARG:-$OLD_USER}"; DB_="${DB_ARG:-${MONGO_INITDB_DATABASE:-}}"; PORT_="${MONGO_PORT:-27017}"
  if   [ -n "$PASS_ARG" ];                 then PASS_="$PASS_ARG";            PW_SRC="provided (--password)"
  elif [ "$GEN" = 1 ];                     then PASS_="$(gen_password)";      PW_SRC="auto-generated (--gen-password)"
  elif [ -n "${MONGO_ROOT_PASSWORD:-}" ];  then PASS_="$MONGO_ROOT_PASSWORD"; PW_SRC="reused from .env"
  else                                          PASS_="$(gen_password)";      PW_SRC="auto-generated (.env was empty)"
  fi
  # write BEFORE `up` so the image's first-init uses it; rotation below enforces it on existing data.
  set_env_var MONGO_ROOT_USER "$USER_"; [ -n "$DB_" ] && set_env_var MONGO_INITDB_DATABASE "$DB_"
  set_env_var MONGO_ROOT_PASSWORD "$PASS_"; set_env_var MONGO_PORT "$PORT_"; set_env_var MONGO_VERSION "$MONGO_VERSION"
}

# mongosh inside the container, authenticated (root@admin). $1=password $2=js
mexec(){ docker compose exec -T "$SVC" mongosh --quiet -u "$USER_" -p "$1" --authenticationDatabase admin --eval "$2" 2>/dev/null; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}" db="${DB_:-test}"
  [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (password shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "============ MongoDB ${MONGO_VERSION} (Docker) — connection details ============"; printf '%s' "$(_c 0)"
  cat <<SUM
  Host / port    : ${host} / ${PORT_}   (container 27017)
  User           : ${USER_}   (built-in role: root @ admin)
  Password       : ${PASS_}   [${PW_SRC}]
  Auth database  : admin
  Database       : ${db}
  Connection URI : mongodb://${USER_}:${PASS_}@${host}:${PORT_}/?authSource=admin
  mongosh (exec) : docker compose exec ${SVC} mongosh -u ${USER_} -p '${PASS_}' --authenticationDatabase admin
  Test from afar : bash ../test.sh "mongodb://${USER_}:${PASS_}@${host}:${PORT_}/?authSource=admin&directConnection=true"
  Data (host)    : ${DATA_DIR}   (bind mount — survives 'down -v')
  Browser UI     : none
  Saved to       : ${ENV_FILE} (chmod 600, gitignored) — the password persists there
SUM
  printf '%s' "$(_c '1;36')"; echo "==============================================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  resolve_creds
  step "1/4  Configuration"; ok "user=${USER_}  db=${DB_:-<none>}  host-port=${PORT_}  password=${PW_SRC}"
  step "2/4  Bind-mount data dir"; sudo mkdir -p "$DATA_DIR/db" "$DATA_DIR/configdb"
  sudo chown -R 999:999 "$DATA_DIR" 2>/dev/null || true   # uid 999 = mongodb inside the image
  ok "$DATA_DIR/{db,configdb}"
  step "3/4  docker compose up -d"; docker compose up -d
  printf '   waiting for healthy'
  for _ in $(seq 1 45); do [ "$(docker inspect -f '{{.State.Health.Status}}' "$CID" 2>/dev/null || echo)" = healthy ] && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  step "4/4  Enforcing credentials + optional database '${DB_:-<none>}'"
  local PWS; PWS="$(jsq "$PASS_")"
  if [ "$(mexec "$PASS_" 'db.runCommand({ping:1}).ok')" = 1 ]; then
    ok "root user '${USER_}' authenticates with the current password"
  elif [ -n "$OLD_PASS" ] && [ "$(mexec "$OLD_PASS" 'db.runCommand({ping:1}).ok')" = 1 ]; then
    mexec "$OLD_PASS" "db.getSiblingDB('admin').updateUser('$(jsq "$USER_")',{pwd:'${PWS}'})" >/dev/null 2>&1 && ok "rotated password for '${USER_}'" || warn "rotate failed"
  else warn "could not authenticate as '${USER_}' — see 'bash setup.sh logs'"; fi
  if [ -n "$DB_" ]; then
    mexec "$PASS_" "db.getSiblingDB('$(jsq "$DB_")').createCollection('_init')" >/dev/null 2>&1 && ok "database '${DB_}' ready" || warn "could not init db '${DB_}'"
  fi
  docker compose ps
  print_summary
}

do_down(){ docker compose down; echo "Container removed. DATA PRESERVED at ${DATA_DIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$DATA_DIR"; echo "Full wipe: container + ${DATA_DIR} removed."; }
do_status(){
  docker compose ps || true
  echo "user/db    : ${MONGO_ROOT_USER:-dokandar} / ${MONGO_INITDB_DATABASE:-test}   (password in ${ENV_FILE})"
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
