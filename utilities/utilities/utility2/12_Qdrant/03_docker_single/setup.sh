#!/usr/bin/env bash
# DOKANDAR utility — Qdrant 1.18 · Docker Compose single-node · lifecycle wrapper.
# Auto-generates the API key (saved to .env), brings the container up, verifies key enforcement.
# Data is a HOST bind mount (${DATA_ROOT}/qdrant_docker) and SURVIVES `docker compose down -v`.
#   Usage:  bash setup.sh up [--gen-key|--key KEY] | down | purge | status | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${QDRANT_HTTP_PORT:=6333}"; : "${QDRANT_GRPC_PORT:=6334}"
DATA_DIR="${DATA_ROOT}/qdrant_docker"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up [--gen-key|--key KEY] | down | purge | status | logs"; }
gen_pw(){ local s; s="$(od -An -tx1 -N18 /dev/urandom | tr -dc 'a-f0-9')"; printf '%s' "${s:0:24}"; }  # SIGPIPE-safe
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true; export "${k}=${v}"
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (API key shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "============ Qdrant (Docker) — connection details ============"; printf '%s' "$(_c 0)"
  cat <<SUM
  REST / HTTP    : http://${host}:${QDRANT_HTTP_PORT}
  gRPC API       : ${host}:${QDRANT_GRPC_PORT}
  API key        : ${QDRANT_API_KEY}   (header: api-key: <key>)
  Browser UI     : http://${host}:${QDRANT_HTTP_PORT}/dashboard   (built-in — paste the key in Settings)
  Test from afar : QDRANT_HOST=${host} QDRANT_HTTP_PORT=${QDRANT_HTTP_PORT} QDRANT_API_KEY=${QDRANT_API_KEY} bash ../test.sh
  Data (host)    : ${DATA_DIR}   (bind mount — survives 'down -v')
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "============================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  step "1/3  Resolve API key + bind-mount data dir"
  if [ -n "$CLI_KEY" ]; then QDRANT_API_KEY="$CLI_KEY"; ok "API key: set via --key"
  elif [ "$GEN_KEY" = 1 ] || [ -z "${QDRANT_API_KEY:-}" ]; then QDRANT_API_KEY="$(gen_pw)"; ok "API key: auto-generated (24-char)"
  else ok "API key: reused from .env"; fi
  set_env_var QDRANT_API_KEY "$QDRANT_API_KEY"; set_env_var QDRANT_HTTP_PORT "$QDRANT_HTTP_PORT"; set_env_var QDRANT_GRPC_PORT "$QDRANT_GRPC_PORT"
  sudo mkdir -p "$DATA_DIR"

  step "2/3  docker compose up -d"
  docker compose up -d
  printf '   waiting for the REST API'; local h=000
  for _ in $(seq 1 30); do h="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${QDRANT_HTTP_PORT}/readyz" 2>/dev/null || echo 000)"; [ "$h" = 200 ] && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  [ "$h" = 200 ] && ok "REST live on :${QDRANT_HTTP_PORT}" || warn "REST not answering yet"

  step "3/3  Verify the API key is enforced"
  local nokey withkey
  nokey="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${QDRANT_HTTP_PORT}/collections" 2>/dev/null || echo 000)"
  withkey="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "api-key: ${QDRANT_API_KEY}" "http://127.0.0.1:${QDRANT_HTTP_PORT}/collections" 2>/dev/null || echo 000)"
  { [ "$nokey" != 200 ] && [ "$withkey" = 200 ]; } && ok "auth enforced (no-key=${nokey}, with-key=${withkey})" || warn "auth check: no-key=${nokey} with-key=${withkey}"
  docker compose ps; print_summary
}

do_down(){ docker compose down; echo "Container removed. DATA PRESERVED at ${DATA_DIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$DATA_DIR"; echo "Full wipe: container + ${DATA_DIR} removed."; }
do_status(){ docker compose ps || true
  curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:${QDRANT_HTTP_PORT}/readyz" 2>/dev/null \
    && echo "readyz     : OK on :${QDRANT_HTTP_PORT}" || echo "readyz     : DOWN on :${QDRANT_HTTP_PORT}"
  echo "data (host): ${DATA_DIR} ($(sudo du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"; }
do_logs(){ docker compose logs --tail=80 -f; }

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
GEN_KEY=0; CLI_KEY=""                              # parse flags AFTER the subcommand is stripped
while [ $# -gt 0 ]; do case "$1" in
  --gen-key) GEN_KEY=1; shift;;
  --key) CLI_KEY="$2"; shift 2;;
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
