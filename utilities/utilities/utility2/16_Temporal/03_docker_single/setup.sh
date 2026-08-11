#!/usr/bin/env bash
# DOKANDAR utility — Temporal · Docker Compose single-node (dev server) · lifecycle wrapper.
# Runs the embedded dev server (admin-tools `temporal server start-dev`) with SQLite + the built-in Web UI;
# verifies the frontend. The SQLite store is a HOST bind mount (${DATA_ROOT}/temporal_docker) and SURVIVES
# `docker compose down -v`.  Usage:  bash setup.sh up | down | purge | status | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${TEMPORAL_GRPC_PORT:=7233}"; : "${TEMPORAL_UI_PORT:=8233}"
: "${TEMPORAL_ADMINTOOLS_IMAGE:=temporalio/admin-tools:latest}"
DATA_DIR="${DATA_ROOT}/temporal_docker"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up | down | purge | status | logs"; }
tcli(){ docker run --rm --network host "$TEMPORAL_ADMINTOOLS_IMAGE" temporal --address "127.0.0.1:${TEMPORAL_GRPC_PORT}" "$@" 2>/dev/null; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details"
  printf '%s' "$(_c '1;36')"; echo "============ Temporal dev server (Docker) — connection details ============"; printf '%s' "$(_c 0)"
  cat <<SUM
  Frontend gRPC  : ${host}:${TEMPORAL_GRPC_PORT}   (default namespace: default)
  Browser UI     : http://${host}:${TEMPORAL_UI_PORT}   (built-in dev-server Web UI)
  Auth           : none (dev server)
  Test from afar : TEMPORAL_HOST=${host} TEMPORAL_GRPC_PORT=${TEMPORAL_GRPC_PORT} bash ../test.sh
  Data (host)    : ${DATA_DIR}   (SQLite store bind mount — survives 'down -v')
SUM
  printf '%s' "$(_c '1;36')"; echo "==========================================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  step "1/2  Bind-mount data dir + docker compose up -d"
  sudo mkdir -p "$DATA_DIR"; sudo chmod 0777 "$DATA_DIR" 2>/dev/null || true   # admin-tools uid varies; SQLite needs write
  docker compose up -d
  printf '   waiting for the frontend'; local up=0
  for _ in $(seq 1 40); do tcli operator namespace list >/dev/null 2>&1 && { echo ' ✓'; up=1; break; }; printf '.'; sleep 2; done
  [ "$up" = 1 ] && ok "frontend answering on :${TEMPORAL_GRPC_PORT}" || warn "frontend not answering yet"

  step "2/2  Verify (cluster system)"
  local ver; ver="$(tcli operator cluster system 2>/dev/null | grep -ioE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  [ -n "$ver" ] && ok "server ${ver}" || warn "version check failed (warming up?)"
  docker compose ps; print_summary
}

do_down(){ docker compose down; echo "Container removed. DATA PRESERVED at ${DATA_DIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$DATA_DIR"; echo "Full wipe: container + ${DATA_DIR} removed."; }
do_status(){ docker compose ps || true
  tcli operator namespace list >/dev/null 2>&1 && echo "frontend   : OK on :${TEMPORAL_GRPC_PORT}" || echo "frontend   : DOWN on :${TEMPORAL_GRPC_PORT}"
  echo "data (host): ${DATA_DIR} ($(sudo du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"; }
do_logs(){ docker compose logs --tail=80 -f; }

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  up|install)     do_up ;;
  down|uninstall) do_down ;;
  purge)          do_purge ;;
  status)         do_status ;;
  logs)           do_logs ;;
  *) usage; exit 2 ;;
esac
