#!/usr/bin/env bash
# DOKANDAR utility — NATS JetStream 2.14 · Docker Compose single-node · lifecycle wrapper.
# Auto-generates the auth token (saved to .env), brings the container up (JetStream on), verifies healthz +
# JetStream. The store is a HOST bind mount (${DATA_ROOT}/nats_docker) and SURVIVES `docker compose down -v`.
#   Usage:  bash setup.sh up [--gen-token|--token T] | down | purge | status | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${NATS_CLIENT_PORT:=4222}"; : "${NATS_MONITOR_PORT:=8222}"
DATA_DIR="${DATA_ROOT}/nats_docker"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up [--gen-token|--token T] | down | purge | status | logs"; }
gen_pw(){ local s; s="$(od -An -tx1 -N18 /dev/urandom | tr -dc 'a-f0-9')"; printf '%s' "${s:0:24}"; }  # SIGPIPE-safe
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true; export "${k}=${v}"
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (token shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "============ NATS JetStream (Docker) — connection details ============"; printf '%s' "$(_c 0)"
  cat <<SUM
  Client URL     : nats://${NATS_AUTH_TOKEN}@${host}:${NATS_CLIENT_PORT}   (token auth, JetStream ON)
  Auth token     : ${NATS_AUTH_TOKEN}
  Monitoring     : http://${host}:${NATS_MONITOR_PORT}/healthz  (JSON; also /varz /jsz — NO HTML UI)
  Test from afar : NATS_HOST=${host} NATS_CLIENT_PORT=${NATS_CLIENT_PORT} NATS_AUTH_TOKEN=${NATS_AUTH_TOKEN} bash ../test.sh
  Data (host)    : ${DATA_DIR}   (JetStream store bind mount — survives 'down -v')
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "====================================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  step "1/3  Resolve token + bind-mount data dir"
  if [ -n "$CLI_TOK" ]; then NATS_AUTH_TOKEN="$CLI_TOK"; ok "token: set via --token"
  elif [ "$GEN_TOK" = 1 ] || [ -z "${NATS_AUTH_TOKEN:-}" ]; then NATS_AUTH_TOKEN="$(gen_pw)"; ok "token: auto-generated (24-char)"
  else ok "token: reused from .env"; fi
  set_env_var NATS_AUTH_TOKEN "$NATS_AUTH_TOKEN"; set_env_var NATS_CLIENT_PORT "$NATS_CLIENT_PORT"; set_env_var NATS_MONITOR_PORT "$NATS_MONITOR_PORT"
  sudo mkdir -p "$DATA_DIR"; sudo chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || true   # nats uid in the image

  step "2/3  docker compose up -d"
  docker compose up -d
  printf '   waiting for :%s/healthz' "$NATS_MONITOR_PORT"; local h=000
  for _ in $(seq 1 30); do h="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${NATS_MONITOR_PORT}/healthz" 2>/dev/null || echo 000)"; [ "$h" = 200 ] && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  [ "$h" = 200 ] && ok "healthz OK on :${NATS_MONITOR_PORT}" || warn "healthz not answering yet"

  step "3/3  Verify JetStream enabled"
  curl -fsS --max-time 5 "http://127.0.0.1:${NATS_MONITOR_PORT}/healthz?js-enabled-only=true" >/dev/null 2>&1 \
    && ok "JetStream enabled" || warn "JetStream check failed"
  docker compose ps; print_summary
}

do_down(){ docker compose down; echo "Container removed. DATA PRESERVED at ${DATA_DIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$DATA_DIR"; echo "Full wipe: container + ${DATA_DIR} removed."; }
do_status(){ docker compose ps || true
  curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:${NATS_MONITOR_PORT}/healthz" 2>/dev/null \
    && echo "healthz    : OK on :${NATS_MONITOR_PORT}" || echo "healthz    : DOWN on :${NATS_MONITOR_PORT}"
  echo "data (host): ${DATA_DIR} ($(sudo du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"; }
do_logs(){ docker compose logs --tail=80 -f; }

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
GEN_TOK=0; CLI_TOK=""                              # parse flags AFTER the subcommand is stripped
while [ $# -gt 0 ]; do case "$1" in
  --gen-token) GEN_TOK=1; shift;;
  --token) CLI_TOK="$2"; shift 2;;
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
