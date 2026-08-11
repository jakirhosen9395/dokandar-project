#!/usr/bin/env bash
# DOKANDAR utility — Prometheus 3.12 · Docker Compose HA (2 replicas + Thanos Querier) · lifecycle wrapper.
# 2 Prometheus replicas scrape the same targets; the Thanos Querier (:10902) fans out + deduplicates by
# the `replica` label. No built-in auth. Per-replica TSDB is HOST bind-mounted (survives down -v).
#   Usage:  bash setup.sh up | down | purge | status | acceptance | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || { echo "No .env here — run:  cp .env.example .env"; exit 2; }
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${PROM_VERSION:=3.12.0}"; : "${THANOS_VERSION:=0.41.0}"
: "${PROM_A_PORT:=9090}"; : "${PROM_B_PORT:=9092}"; : "${THANOS_PORT:=10902}"
DATA_DIR="${DATA_ROOT}/prometheus_cluster"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up | down | purge | status | acceptance | logs"; }
wait_http(){ for _ in $(seq 1 30); do curl -s --max-time 3 "$1" >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details"
  printf '%s' "$(_c '1;36')"; echo "===== Prometheus ${PROM_VERSION} HA (2 replicas + Thanos Querier) — connection details ====="; printf '%s' "$(_c 0)"
  cat <<SUM
  Thanos Querier : http://${host}:${THANOS_PORT}   (unified, DEDUPLICATED query API + UI; use THIS)
  Replica A      : http://${host}:${PROM_A_PORT}   (raw Prometheus, external_labels replica=a)
  Replica B      : http://${host}:${PROM_B_PORT}   (raw Prometheus, external_labels replica=b)
  Auth           : none (restrict at the firewall)
  Test (cluster) : bash ../test.sh "http://${host}:${THANOS_PORT}"
  Verify HA      : bash setup.sh acceptance
  Data (host)    : ${DATA_DIR}/{a,b}   (bind mounts — survive 'down -v')
  Browser UI     : http://${host}:${THANOS_PORT}  (Thanos query UI)
SUM
  printf '%s' "$(_c '1;36')"; echo "==============================================================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  step "1/3  Configuration"; ok "replicas :${PROM_A_PORT},:${PROM_B_PORT}  querier :${THANOS_PORT}  thanos=${THANOS_VERSION}"
  step "2/3  Per-replica data dirs + docker compose up (2 prom + 2 sidecar + querier)"
  for n in a b; do sudo mkdir -p "$DATA_DIR/$n"; done; sudo chown -R 65534:65534 "$DATA_DIR"
  docker compose up -d
  printf '   waiting for replicas + querier'
  wait_http "http://localhost:${PROM_A_PORT}/-/healthy" && wait_http "http://localhost:${PROM_B_PORT}/-/healthy" && wait_http "http://localhost:${THANOS_PORT}/-/healthy" && echo ' ✓' || warn "not all up yet"
  step "3/3  Stores"
  local ns; ns="$(curl -s --max-time 5 "http://localhost:${THANOS_PORT}/api/v1/stores" 2>/dev/null | grep -oE '"name":"[^"]*:10901"' | wc -l | tr -d ' ')"
  ok "Thanos Querier sees ${ns:-?} store(s)"
  docker compose ps
  print_summary
}

do_acceptance(){
  echo "== (1) both Prometheus replicas healthy =="
  for p in "${PROM_A_PORT}:A" "${PROM_B_PORT}:B"; do
    curl -s --max-time 5 "http://localhost:${p%%:*}/-/healthy" 2>/dev/null | grep -qi healthy && echo "   replica ${p##*:} (:${p%%:*}) healthy" || echo "   FAIL: replica ${p##*:} down"
  done
  echo "== (2) Thanos Querier sees 2 stores =="
  local ns; ns="$(curl -s --max-time 5 "http://localhost:${THANOS_PORT}/api/v1/stores" 2>/dev/null | grep -oE ':10901"' | wc -l | tr -d ' ')"
  echo "   stores: ${ns}"; [ "${ns:-0}" = 2 ] && echo "OK: 2 stores" || echo "FAIL: expected 2 stores"
  echo "== (3) querier dedups the two replicas (1 series per target, replica label collapsed) =="
  local d; d="$(curl -s --max-time 10 "http://localhost:${THANOS_PORT}/api/v1/query?query=up&dedup=true" 2>/dev/null | grep -oE '"replica":"[ab]"' | wc -l | tr -d ' ')"
  local nd; nd="$(curl -s --max-time 10 "http://localhost:${THANOS_PORT}/api/v1/query?query=up&dedup=false" 2>/dev/null | grep -oE '"replica":"[ab]"' | wc -l | tr -d ' ')"
  echo "   replica-labelled series: dedup=true -> ${d}, dedup=false -> ${nd}"
  [ "${d:-1}" = 0 ] && [ "${nd:-0}" -gt 0 ] && echo "OK: dedup collapses the replica label" || echo "NOTE: dedup d=${d} nd=${nd}"
}

do_down(){ docker compose down; echo "Containers removed. DATA PRESERVED at ${DATA_DIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$DATA_DIR"; echo "Full wipe: containers + ${DATA_DIR} removed."; }
do_status(){ docker compose ps || true; echo "data: ${DATA_DIR} ($(sudo du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"; }
do_logs(){ docker compose logs --tail=80 -f; }

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  up|install) do_up ;; down|uninstall) do_down ;; purge) do_purge ;; status) do_status ;; acceptance) do_acceptance ;; logs) do_logs ;;
  *) usage; exit 2 ;;
esac
