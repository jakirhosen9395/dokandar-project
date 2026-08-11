#!/usr/bin/env bash
# DOKANDAR utility — ScyllaDB 2026.1 · Docker Compose single-node · lifecycle wrapper.
# Brings the node up (developer mode, capped resources) and verifies a CQL query. ScyllaDB has no auth by
# default. Data is a HOST bind mount (${DATA_ROOT}/scylla_docker) and SURVIVES `docker compose down -v`.
#   Usage:  bash setup.sh up | down | purge | status | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${SCYLLA_CQL_PORT:=9042}"; : "${SCYLLA_IMAGE:=scylladb/scylla:2026.1}"
DATA_DIR="${DATA_ROOT}/scylla_docker"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up | down | purge | status | logs"; }
cql(){ docker run --rm --network host --entrypoint cqlsh "$SCYLLA_IMAGE" 127.0.0.1 "$SCYLLA_CQL_PORT" --request-timeout=20 -e "$1" 2>/dev/null; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details"
  printf '%s' "$(_c '1;36')"; echo "============ ScyllaDB (Docker) — connection details ============"; printf '%s' "$(_c 0)"
  cat <<SUM
  CQL endpoint   : ${host}:${SCYLLA_CQL_PORT}
  Auth           : none (authenticator off by default — no username/password)
  Browser UI     : none — N/A (CQL database; interact via cqlsh / nodetool)
  cqlsh smoke    : docker run --rm -it --entrypoint cqlsh ${SCYLLA_IMAGE} ${host} ${SCYLLA_CQL_PORT}
  Test from afar : SCYLLA_HOST=${host} SCYLLA_CQL_PORT=${SCYLLA_CQL_PORT} bash ../test.sh
  Data (host)    : ${DATA_DIR}   (bind mount — survives 'down -v')
SUM
  printf '%s' "$(_c '1;36')"; echo "==============================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  step "1/3  Bind-mount data dir"
  sudo mkdir -p "$DATA_DIR"; sudo chown -R 999:999 "$DATA_DIR" 2>/dev/null || true   # scylla uid in the image

  step "2/3  docker compose up -d (ScyllaDB boot is slow ~30-60s)"
  docker compose up -d
  printf '   waiting for CQL :%s' "$SCYLLA_CQL_PORT"; local up=0
  for _ in $(seq 1 40); do cql "SELECT now() FROM system.local;" 2>/dev/null | grep -q '(1 rows)' && { echo ' ✓'; up=1; break; }; printf '.'; sleep 3; done
  [ "$up" = 1 ] && ok "CQL live on :${SCYLLA_CQL_PORT}" || warn "CQL not answering yet"

  step "3/3  Verify (nodetool status + release_version)"
  docker exec dokandar_scylla_docker_single nodetool status 2>/dev/null | grep -E '^UN' | sed 's/^/   /' || true
  local ver; ver="$(cql "SELECT release_version FROM system.local;" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^ ]*' | head -1)"
  [ -n "$ver" ] && ok "query OK — release ${ver}" || warn "query failed (warming up?)"
  docker compose ps; print_summary
}

do_down(){ docker compose down; echo "Container removed. DATA PRESERVED at ${DATA_DIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$DATA_DIR"; echo "Full wipe: container + ${DATA_DIR} removed."; }
do_status(){ docker compose ps || true
  cql "SELECT release_version FROM system.local;" 2>/dev/null | grep -qE '[0-9]' && echo "CQL        : OK on :${SCYLLA_CQL_PORT}" || echo "CQL        : DOWN on :${SCYLLA_CQL_PORT}"
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
