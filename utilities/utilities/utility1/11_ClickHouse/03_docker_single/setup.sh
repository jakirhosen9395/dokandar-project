#!/usr/bin/env bash
# DOKANDAR utility — ClickHouse 26.3 LTS · Docker Compose single-node · lifecycle wrapper.
# Auto-generates the password (saved to .env), brings the container up, verifies the creds over HTTP.
# Data is a HOST bind mount (${DATA_ROOT}/clickhouse_docker) and SURVIVES `docker compose down -v`.
#   Usage:  bash setup.sh up [--user U] [--gen-password|--password P] | down | purge | status | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${CLICKHOUSE_HTTP_PORT:=8123}"; : "${CLICKHOUSE_TCP_PORT:=9000}"
: "${CLICKHOUSE_USER:=default}"
DATA_DIR="${DATA_ROOT}/clickhouse_docker"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up [--user U] [--gen-password|--password P] | down | purge | status | logs"; }
gen_pw(){ local s; s="$(od -An -tx1 -N18 /dev/urandom | tr -dc 'a-f0-9')"; printf '%s' "${s:0:24}"; }  # SIGPIPE-safe
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true; export "${k}=${v}"
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (password shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "============ ClickHouse (Docker) — connection details ============"; printf '%s' "$(_c 0)"
  cat <<SUM
  HTTP interface : http://${host}:${CLICKHOUSE_HTTP_PORT}
  Native TCP     : ${host}:${CLICKHOUSE_TCP_PORT}
  Username       : ${CLICKHOUSE_USER}
  Password       : ${CLICKHOUSE_PASSWORD}
  Browser UI     : http://${host}:${CLICKHOUSE_HTTP_PORT}/play   (built-in SQL console)
  Test from afar : CLICKHOUSE_HOST=${host} CLICKHOUSE_HTTP_PORT=${CLICKHOUSE_HTTP_PORT} CLICKHOUSE_USER=${CLICKHOUSE_USER} CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD} bash ../test.sh
  Data (host)    : ${DATA_DIR}   (bind mount — survives 'down -v')
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "================================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  step "1/3  Resolve credentials + bind-mount data dir"
  if [ -n "$CLI_PW" ]; then CLICKHOUSE_PASSWORD="$CLI_PW"; ok "password: set via --password"
  elif [ "$GEN_PW" = 1 ] || [ -z "${CLICKHOUSE_PASSWORD:-}" ]; then CLICKHOUSE_PASSWORD="$(gen_pw)"; ok "password: auto-generated (24-char)"
  else ok "password: reused from .env"; fi
  set_env_var CLICKHOUSE_USER "$CLICKHOUSE_USER"; set_env_var CLICKHOUSE_PASSWORD "$CLICKHOUSE_PASSWORD"
  set_env_var CLICKHOUSE_HTTP_PORT "$CLICKHOUSE_HTTP_PORT"; set_env_var CLICKHOUSE_TCP_PORT "$CLICKHOUSE_TCP_PORT"
  sudo mkdir -p "$DATA_DIR"; sudo chown -R 101:101 "$DATA_DIR" 2>/dev/null || true   # clickhouse uid in the image

  step "2/3  docker compose up -d"
  docker compose up -d
  printf '   waiting for the HTTP interface'; local h=000
  for _ in $(seq 1 40); do h="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${CLICKHOUSE_HTTP_PORT}/ping" 2>/dev/null || echo 000)"; [ "$h" = 200 ] && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  [ "$h" = 200 ] && ok "HTTP live on :${CLICKHOUSE_HTTP_PORT}" || warn "HTTP not answering yet on :${CLICKHOUSE_HTTP_PORT}"

  step "3/3  Verify credentials end-to-end (SELECT version)"
  local VER; VER="$(printf 'SELECT version()' | curl -s --max-time 10 -u "${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}" "http://127.0.0.1:${CLICKHOUSE_HTTP_PORT}/" --data-binary @- 2>/dev/null)"
  [ -n "$VER" ] && ok "query OK — version ${VER}" || warn "query failed (warming up?)"
  docker compose ps; print_summary
}

do_down(){ docker compose down; echo "Container removed. DATA PRESERVED at ${DATA_DIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$DATA_DIR"; echo "Full wipe: container + ${DATA_DIR} removed."; }
do_status(){ docker compose ps || true
  curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:${CLICKHOUSE_HTTP_PORT}/ping" 2>/dev/null \
    && echo "HTTP /ping : OK on :${CLICKHOUSE_HTTP_PORT}" || echo "HTTP /ping : DOWN on :${CLICKHOUSE_HTTP_PORT}"
  echo "data (host): ${DATA_DIR} ($(sudo du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"; }
do_logs(){ docker compose logs --tail=80 -f; }

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
GEN_PW=0; CLI_PW=""                                # parse flags AFTER the subcommand is stripped
while [ $# -gt 0 ]; do case "$1" in
  --user) CLICKHOUSE_USER="$2"; shift 2;;
  --gen-password) GEN_PW=1; shift;;
  --password) CLI_PW="$2"; shift 2;;
  *) break;;
esac; done
case "$cmd" in
  up|install)     do_up ;;
  down|uninstall) do_down ;;
  purge)          do_purge ;;
  status)         do_status ;;
  logs)           do_logs ;;
  *) usage; exit 2 ;;
esac
