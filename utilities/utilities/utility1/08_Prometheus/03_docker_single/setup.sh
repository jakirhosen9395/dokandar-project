#!/usr/bin/env bash
# DOKANDAR utility — Prometheus 3.12 · Docker Compose single-node · lifecycle wrapper.
# No built-in auth. Data is a HOST bind mount (${DATA_ROOT}/prometheus_docker) and SURVIVES
# `docker compose down -v`.  Usage:  bash setup.sh up | down | purge | status | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || { echo "No .env here — run:  cp .env.example .env"; exit 2; }
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${PROM_VERSION:=3.12.0}"; : "${PROMETHEUS_PORT:=9090}"
DATA_DIR="${DATA_ROOT}/prometheus_docker"; CID=dokandar_prometheus_docker_single

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up | down | purge | status | logs"; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details"
  printf '%s' "$(_c '1;36')"; echo "============ Prometheus ${PROM_VERSION} (Docker) — connection details ============"; printf '%s' "$(_c 0)"
  cat <<SUM
  HTTP API + UI  : http://${host}:${PROMETHEUS_PORT}   (container 9090; built-in web UI)
  Health / ready : http://${host}:${PROMETHEUS_PORT}/-/healthy , /-/ready
  Auth           : none (Prometheus has no built-in auth — restrict at the firewall)
  Test from afar : bash ../test.sh "http://${host}:${PROMETHEUS_PORT}"
  Data (host)    : ${DATA_DIR}   (bind mount — survives 'down -v')
  Browser UI     : http://${host}:${PROMETHEUS_PORT}
SUM
  printf '%s' "$(_c '1;36')"; echo "================================================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  step "1/3  Configuration"; ok "host-port=${PROMETHEUS_PORT}  image=prom/prometheus:v${PROM_VERSION}  auth=none"
  step "2/3  Bind-mount data dir + docker compose up -d"; sudo mkdir -p "$DATA_DIR"; sudo chown -R 65534:65534 "$DATA_DIR"   # nobody
  docker compose up -d
  step "3/3  Verify"
  printf '   waiting for /-/healthy'
  for _ in $(seq 1 30); do curl -s --max-time 3 "http://localhost:${PROMETHEUS_PORT}/-/healthy" 2>/dev/null | grep -qi healthy && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  curl -s --max-time 5 "http://localhost:${PROMETHEUS_PORT}/-/healthy" 2>/dev/null | grep -qi healthy && ok "Prometheus healthy on :${PROMETHEUS_PORT}" || warn "not ready — see 'bash setup.sh logs'"
  docker compose ps
  print_summary
}

do_down(){ docker compose down; echo "Container removed. DATA PRESERVED at ${DATA_DIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$DATA_DIR"; echo "Full wipe: container + ${DATA_DIR} removed."; }
do_status(){ docker compose ps || true; echo "data (host): ${DATA_DIR} ($(sudo du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"; }
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
