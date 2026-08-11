#!/usr/bin/env bash
# DOKANDAR utility — RabbitMQ 4.x · Docker Compose single-node (Management UI) · lifecycle wrapper.
# Auth ON (admin user); auto-generates a COMPLEX password when none is set; --gen-password rotates.
# Data is a HOST bind mount (${DATA_ROOT}/rabbitmq_docker) and SURVIVES `docker compose down -v`.
#   Usage:  bash setup.sh up [--user U] [--password P | --gen-password] | down | purge | status | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || { echo "No .env here — run:  cp .env.example .env"; exit 2; }
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${RABBITMQ_IMAGE_TAG:=4-management}"; : "${RABBITMQ_AMQP_PORT:=5672}"; : "${RABBITMQ_MGMT_PORT:=15672}"
DATA_DIR="${DATA_ROOT}/rabbitmq_docker"; CID=dokandar_rabbitmq_docker_single; SVC=rabbitmq

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up [--user U] [--password P | --gen-password] | down | purge | status | logs"; }

gen_password(){ printf '%s' "$( set +o pipefail
  { command -v openssl >/dev/null 2>&1 && openssl rand -base64 48 || head -c 256 /dev/urandom; } \
  | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24 )"; }
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true; export "${k}=${v}"
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }

USER_ARG=""; PASS_ARG=""; GEN=0
parse_args(){ while [ $# -gt 0 ]; do case "$1" in
    --user) USER_ARG="${2:?}"; shift 2;; --user=*) USER_ARG="${1#*=}"; shift;;
    --password) PASS_ARG="${2:?}"; shift 2;; --password=*) PASS_ARG="${1#*=}"; shift;;
    --gen-password) GEN=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1"; usage; exit 2;;
  esac; done; }

OLD_PASS=""
resolve_creds(){
  OLD_PASS="${RABBITMQ_DEFAULT_PASS:-}"
  USER_="${USER_ARG:-${RABBITMQ_DEFAULT_USER:-dokandar}}"
  if   [ -n "$PASS_ARG" ];                  then PASS_="$PASS_ARG";              PW_SRC="provided (--password)"
  elif [ "$GEN" = 1 ];                      then PASS_="$(gen_password)";        PW_SRC="auto-generated (--gen-password)"
  elif [ -n "${RABBITMQ_DEFAULT_PASS:-}" ]; then PASS_="$RABBITMQ_DEFAULT_PASS"; PW_SRC="reused from .env"
  else                                           PASS_="$(gen_password)";        PW_SRC="auto-generated (.env was empty)"
  fi
  set_env_var RABBITMQ_DEFAULT_USER "$USER_"; set_env_var RABBITMQ_DEFAULT_PASS "$PASS_"
  set_env_var RABBITMQ_AMQP_PORT "$RABBITMQ_AMQP_PORT"; set_env_var RABBITMQ_MGMT_PORT "$RABBITMQ_MGMT_PORT"; set_env_var RABBITMQ_IMAGE_TAG "$RABBITMQ_IMAGE_TAG"
}

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (password shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "============ RabbitMQ ${RABBITMQ_IMAGE_TAG} (Docker) — connection details ============"; printf '%s' "$(_c 0)"
  cat <<SUM
  AMQP endpoint  : ${host}:${RABBITMQ_AMQP_PORT}   (container 5672)
  User           : ${USER_}   (administrator)
  Password       : ${PASS_}   [${PW_SRC}]
  AMQP URL       : amqp://${USER_}:${PASS_}@${host}:${RABBITMQ_AMQP_PORT}/
  Browser UI     : http://${host}:${RABBITMQ_MGMT_PORT}   (Management plugin)
  Test from afar : bash ../test.sh "http://${USER_}:${PASS_}@${host}:${RABBITMQ_MGMT_PORT}"
  Data (host)    : ${DATA_DIR}   (bind mount — survives 'down -v')
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "============================================================================="; printf '%s' "$(_c 0)"
}

# rabbitmqctl inside the container. $@ = ctl args
rc(){ docker compose exec -T "$SVC" rabbitmqctl "$@" 2>/dev/null; }

do_up(){
  resolve_creds
  step "1/3  Configuration"; ok "user=${USER_}  amqp=${RABBITMQ_AMQP_PORT}  mgmt=${RABBITMQ_MGMT_PORT}  password=${PW_SRC}"
  step "2/3  Bind-mount data dir + docker compose up -d"; sudo mkdir -p "$DATA_DIR"; sudo chown -R 999:999 "$DATA_DIR"   # uid 999 = rabbitmq
  docker compose up -d
  printf '   waiting for healthy'
  for _ in $(seq 1 45); do [ "$(docker inspect -f '{{.State.Health.Status}}' "$CID" 2>/dev/null || echo)" = healthy ] && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  step "3/3  Verify / rotate the admin password"
  if rc authenticate_user "$USER_" "$PASS_" >/dev/null 2>&1; then ok "user '${USER_}' authenticates"
  elif [ -n "$OLD_PASS" ] && rc authenticate_user "$USER_" "$OLD_PASS" >/dev/null 2>&1; then
    rc change_password "$USER_" "$PASS_" >/dev/null 2>&1 && ok "rotated password for '${USER_}'" || warn "rotate failed"
  else warn "could not authenticate '${USER_}' — see 'bash setup.sh logs'"; fi
  docker compose ps
  print_summary
}

do_down(){ docker compose down; echo "Container removed. DATA PRESERVED at ${DATA_DIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$DATA_DIR"; echo "Full wipe: container + ${DATA_DIR} removed."; }
do_status(){ docker compose ps || true; echo "data (host): ${DATA_DIR} ($(sudo du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"; }
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
