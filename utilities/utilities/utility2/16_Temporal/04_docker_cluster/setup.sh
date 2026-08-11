#!/usr/bin/env bash
# DOKANDAR utility — Temporal · Docker Compose HA cluster (PostgreSQL + 3 temporal-server nodes + UI).
# Auto-generates the PG password, brings up PG + node1 (runs schema setup), then nodes 2/3 (skip setup) +
# the UI, and runs the acceptance gate: 3 frontends reachable; a namespace created via node1 is visible on
# node2 AND node3 (shared store + cache propagation); a node-down failover still serves. PG + per-node data
# are HOST bind mounts (survive `down -v`).
#   Usage:  bash setup.sh up [--gen-password|--password P] | down | purge | status | accept | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${TEMPORAL_ADMINTOOLS_IMAGE:=temporalio/admin-tools:latest}"
: "${T_GRPC1:=7233}"; : "${T_GRPC2:=7234}"; : "${T_GRPC3:=7235}"; : "${T_UI:=8233}"
CDIR="${DATA_ROOT}/temporal_cluster"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up [--gen-password|--password P] | down | purge | status | accept | logs"; }
gen_pw(){ local s; s="$(od -An -tx1 -N18 /dev/urandom | tr -dc 'a-f0-9')"; printf '%s' "${s:0:24}"; }  # SIGPIPE-safe
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true; export "${k}=${v}"
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }
# temporal CLI against the node on host gRPC port $1; remaining args go to the CLI.
tc(){ local p="$1"; shift; docker run --rm --network host "$TEMPORAL_ADMINTOOLS_IMAGE" temporal --address "127.0.0.1:${p}" "$@" 2>/dev/null; }
frontend_up(){ tc "$1" operator namespace list >/dev/null 2>&1; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (PG password shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "===== Temporal HA cluster (PG + 3 servers) — connection details ====="; printf '%s' "$(_c 0)"
  cat <<SUM
  Frontend gRPC  : ${host}:${T_GRPC1} (n1), :${T_GRPC2} (n2), :${T_GRPC3} (n3)
                   stateless servers sharing one PostgreSQL store; any frontend serves the cluster
  Browser UI     : http://${host}:${T_UI}   (companion temporalio/ui)
  PostgreSQL     : user=temporal  password=${PG_PASSWORD}  (store: temporal + temporal_visibility)
  Auth           : none on the frontend (dev posture; SG-fenced)
  Test from afar : TEMPORAL_HOST=${host} TEMPORAL_GRPC_PORT=${T_GRPC1} bash ../test.sh
  Data (host)    : ${CDIR}/{pg}   (PG store bind mount — survives 'down -v')
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "====================================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  step "1/4  Resolve PG password + data dir"
  if [ -n "$CLI_PW" ]; then PG_PASSWORD="$CLI_PW"; ok "PG password: set via --password"
  elif [ "$GEN_PW" = 1 ] || [ -z "${PG_PASSWORD:-}" ]; then PG_PASSWORD="$(gen_pw)"; ok "PG password: auto-generated (24-char)"
  else ok "PG password: reused from .env"; fi
  set_env_var PG_PASSWORD "$PG_PASSWORD"
  set_env_var T_GRPC1 "$T_GRPC1"; set_env_var T_GRPC2 "$T_GRPC2"; set_env_var T_GRPC3 "$T_GRPC3"
  sudo mkdir -p "$CDIR"/pg; sudo chown -R 999:999 "$CDIR"/pg 2>/dev/null || true   # postgres uid

  step "2/4  Bring up PostgreSQL + node1 (node1 runs schema setup)"
  docker compose up -d postgres temporal1
  printf '   waiting for node1 frontend (schema setup runs first)'; local up=0
  for _ in $(seq 1 60); do frontend_up "$T_GRPC1" && { echo ' ✓'; up=1; break; }; printf '.'; sleep 3; done
  [ "$up" = 1 ] && ok "node1 frontend up (schema initialised)" || warn "node1 not up yet"

  step "3/4  Bring up nodes 2 + 3 (skip schema) + the Web UI"
  docker compose up -d
  for p in "$T_GRPC2" "$T_GRPC3"; do
    printf '   waiting for frontend :%s' "$p"; local u=0
    for _ in $(seq 1 40); do frontend_up "$p" && { echo ' ✓'; u=1; break; }; printf '.'; sleep 3; done
    [ "$u" = 1 ] || warn "frontend :${p} not up yet"
  done

  step "4/4  Cluster membership (3 frontends)"
  local n=0; for p in "$T_GRPC1" "$T_GRPC2" "$T_GRPC3"; do frontend_up "$p" && n=$((n+1)); done
  ok "frontends reachable: ${n}/3"
  docker compose ps
  print_summary
  do_accept || warn "acceptance had warnings — see above"
}

do_accept(){
  step "Acceptance — 3 frontends / namespace shared across nodes / node-down failover"
  local rc=0 NS="hachk_$(date +%s)"
  echo "== (1) 3 frontends reachable =="
  local n=0; for p in "$T_GRPC1" "$T_GRPC2" "$T_GRPC3"; do frontend_up "$p" && n=$((n+1)); done
  [ "$n" = 3 ] && ok "all 3 frontends answer" || { warn "frontends up=${n}/3"; rc=1; }

  echo "== (2) namespace created via node1 is visible on node2 + node3 (shared store) =="
  tc "$T_GRPC1" operator namespace create "$NS" --retention 24h --description 'চাল-rice' >/dev/null 2>&1
  # each frontend caches namespaces and refreshes on an interval — retry the cross-node describe.
  local v2=0 v3=0
  for _ in $(seq 1 20); do tc "$T_GRPC2" operator namespace describe "$NS" >/dev/null 2>&1 && { v2=1; break; }; sleep 2; done
  for _ in $(seq 1 20); do tc "$T_GRPC3" operator namespace describe "$NS" >/dev/null 2>&1 && { v3=1; break; }; sleep 2; done
  [ "$v2" = 1 ] && ok "node2 sees the namespace created on node1" || { warn "node2 cannot see it"; rc=1; }
  [ "$v3" = 1 ] && ok "node3 sees the namespace created on node1" || { warn "node3 cannot see it"; rc=1; }
  # the namespace appears in node2's cache a beat before its Description field refreshes — poll for the value.
  local d2=0; for _ in $(seq 1 10); do tc "$T_GRPC2" operator namespace describe "$NS" 2>/dev/null | grep -q 'চাল-rice' && { d2=1; break; }; sleep 2; done
  [ "$d2" = 1 ] && ok "UTF-8 description intact on node2" || { warn "node2 desc mismatch"; rc=1; }

  echo "== (3) failover: stop node3, namespace ops still work via node1/node2 =="
  docker compose stop temporal3 >/dev/null 2>&1 || true; sleep 5
  local f=0; for _ in $(seq 1 12); do frontend_up "$T_GRPC1" && tc "$T_GRPC2" operator namespace describe "$NS" >/dev/null 2>&1 && { f=1; break; }; sleep 2; done
  [ "$f" = 1 ] && ok "cluster still serves via node1/node2 with node3 down" || { warn "failover check failed"; rc=1; }
  docker compose start temporal3 >/dev/null 2>&1 || true
  local c=0; for _ in $(seq 1 20); do frontend_up "$T_GRPC3" && { c=1; break; }; sleep 3; done
  [ "$c" = 1 ] && ok "node3 frontend re-joined" || warn "node3 rejoin slow"

  tc "$T_GRPC1" operator namespace delete "$NS" --yes >/dev/null 2>&1 || true
  [ "$rc" = 0 ] && ok "ACCEPTANCE PASS" || warn "ACCEPTANCE had failures"
  return "$rc"
}

do_down(){ docker compose down; echo "Containers removed. DATA PRESERVED at ${CDIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$CDIR"; echo "Full wipe: containers + ${CDIR} removed."; }
do_status(){ docker compose ps || true
  for p in "$T_GRPC1" "$T_GRPC2" "$T_GRPC3"; do frontend_up "$p" && echo "  frontend :${p} -> OK" || echo "  frontend :${p} -> DOWN"; done
  echo "data (host): ${CDIR} ($(sudo du -sh "$CDIR" 2>/dev/null | cut -f1 || echo absent))"; }
do_logs(){ docker compose logs --tail=80 -f; }

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
GEN_PW=0; CLI_PW=""                                # parse flags AFTER the subcommand is stripped
while [ $# -gt 0 ]; do case "$1" in
  --gen-password) GEN_PW=1; shift;;
  --password) CLI_PW="$2"; shift 2;;
  *) break;;
esac; done
case "$cmd" in
  up|install)     do_up ;;
  accept)         do_accept ;;
  down|uninstall) do_down ;;
  purge)          do_purge ;;
  status)         do_status ;;
  logs)           do_logs ;;
  *) usage; exit 2 ;;
esac
