#!/usr/bin/env bash
# DOKANDAR utility — Redis 8 · Docker Compose single-node · lifecycle wrapper.
# Auth ON (requirepass); auto-generates a COMPLEX password when none is set; --gen-password rotates.
# Data is a HOST bind mount (${DATA_ROOT}/redis_docker, AOF) and SURVIVES `docker compose down -v`.
#   Usage:  bash setup.sh up [--password P | --gen-password] | down | purge | status | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || { echo "No .env here — run:  cp .env.example .env"; exit 2; }
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${REDIS_VERSION:=8}"; : "${REDIS_PORT:=6379}"
DATA_DIR="${DATA_ROOT}/redis_docker"; CID=dokandar_redis_docker_single; SVC=redis

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up [--password P | --gen-password] | down | purge | status | logs"; }

gen_password(){ printf '%s' "$( set +o pipefail
  { command -v openssl >/dev/null 2>&1 && openssl rand -base64 48 || head -c 256 /dev/urandom; } \
  | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24 )"; }
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true; export "${k}=${v}"
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }

PASS_ARG=""; GEN=0
parse_args(){ while [ $# -gt 0 ]; do case "$1" in
    --password) PASS_ARG="${2:?}"; shift 2;; --password=*) PASS_ARG="${1#*=}"; shift;;
    --gen-password) GEN=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1"; usage; exit 2;;
  esac; done; }

resolve_creds(){
  if   [ -n "$PASS_ARG" ];               then PASS_="$PASS_ARG";            PW_SRC="provided (--password)"
  elif [ "$GEN" = 1 ];                   then PASS_="$(gen_password)";      PW_SRC="auto-generated (--gen-password)"
  elif [ -n "${REDIS_PASSWORD:-}" ];     then PASS_="$REDIS_PASSWORD";      PW_SRC="reused from .env"
  else                                        PASS_="$(gen_password)";      PW_SRC="auto-generated (.env was empty)"
  fi
  set_env_var REDIS_PASSWORD "$PASS_"; set_env_var REDIS_PORT "$REDIS_PORT"; set_env_var REDIS_VERSION "$REDIS_VERSION"
}

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (password shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "============ Redis ${REDIS_VERSION} (Docker) — connection details ============"; printf '%s' "$(_c 0)"
  cat <<SUM
  Endpoint       : ${host}:${REDIS_PORT}   (container 6379)
  Auth           : requirepass (ACL 'default' user)
  Password       : ${PASS_}   [${PW_SRC}]
  Connection URL : redis://default:${PASS_}@${host}:${REDIS_PORT}/0
  redis-cli      : redis-cli -h ${host} -p ${REDIS_PORT} -a '${PASS_}' ping     # -> PONG
  Test from afar : bash ../test.sh "redis://default:${PASS_}@${host}:${REDIS_PORT}"
  Data (host)    : ${DATA_DIR}   (bind mount, AOF — survives 'down -v')
  Browser UI     : none
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "============================================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  resolve_creds
  step "1/3  Configuration"; ok "host-port=${REDIS_PORT}  auth=on  image=redis:${REDIS_VERSION}  password=${PW_SRC}"
  step "2/3  Bind-mount data dir + docker compose up -d"; sudo mkdir -p "$DATA_DIR"; sudo chown -R 999:999 "$DATA_DIR"   # uid 999 = redis in image
  docker compose up -d
  printf '   waiting for healthy'
  for _ in $(seq 1 30); do [ "$(docker inspect -f '{{.State.Health.Status}}' "$CID" 2>/dev/null || echo)" = healthy ] && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  step "3/3  Verify"
  local PONG; PONG="$(docker compose exec -T "$SVC" redis-cli -a "$PASS_" --no-auth-warning ping 2>/dev/null)"
  [ "$PONG" = PONG ] && ok "auth OK — PING -> PONG" || warn "PING failed — see 'bash setup.sh logs'"
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
