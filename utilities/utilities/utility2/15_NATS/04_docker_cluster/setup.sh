#!/usr/bin/env bash
# DOKANDAR utility — NATS JetStream 2.14 · Docker Compose HA cluster (3 symmetric nodes, route mesh).
# Auto-generates the token, brings up the 3 nodes, and runs the acceptance gate: routes meshed (each node
# sees 2 routes); a JetStream R3 KV bucket written via node1 reads back via node2 AND node3; a node-down
# failover still serves. Per-node store = HOST bind mounts (survive `down -v`).
#   Usage:  bash setup.sh up [--gen-token|--token T] | down | purge | status | accept | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${NATS_BOX_IMAGE:=natsio/nats-box:latest}"
: "${N_CLIENT1:=4222}"; : "${N_CLIENT2:=4223}"; : "${N_CLIENT3:=4224}"
: "${N_MON1:=8222}"; : "${N_MON2:=8223}"; : "${N_MON3:=8224}"
CDIR="${DATA_ROOT}/nats_cluster"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up [--gen-token|--token T] | down | purge | status | accept | logs"; }
gen_pw(){ local s; s="$(od -An -tx1 -N18 /dev/urandom | tr -dc 'a-f0-9')"; printf '%s' "${s:0:24}"; }  # SIGPIPE-safe
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true; export "${k}=${v}"
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }
# nats CLI against the node on client port $1; remaining args go to the nats CLI.
na(){ local p="$1"; shift; docker run --rm --network host "$NATS_BOX_IMAGE" nats -s "nats://${NATS_AUTH_TOKEN}@127.0.0.1:${p}" "$@" 2>/dev/null; }
nroutes(){ curl -s --max-time 5 "http://127.0.0.1:${1}/routez" 2>/dev/null | grep -oE '"num_routes": *[0-9]+' | grep -oE '[0-9]+' | head -1; }
healthz(){ curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${1}/healthz" 2>/dev/null || echo 000; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (token shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "===== NATS JetStream HA cluster (3-node mesh) — connection details ====="; printf '%s' "$(_c 0)"
  cat <<SUM
  Client URLs    : nats://<token>@${host}:${N_CLIENT1} (n1), :${N_CLIENT2} (n2), :${N_CLIENT3} (n3)
                   symmetric — any node accepts pub/sub; R3 streams RAFT-replicated across all 3
  Auth token     : ${NATS_AUTH_TOKEN}   (identical on all 3 nodes)
  Monitoring     : http://${host}:${N_MON1}/jsz (n1), :${N_MON2}, :${N_MON3}  (JSON; NO HTML UI)
  Test from afar : NATS_HOST=${host} NATS_CLIENT_PORT=${N_CLIENT1} NATS_AUTH_TOKEN=${NATS_AUTH_TOKEN} bash ../test.sh
  Data (host)    : ${CDIR}/n{1,2,3}   (JetStream store bind mounts — survive 'down -v')
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "========================================================================"; printf '%s' "$(_c 0)"
}

do_up(){
  step "1/3  Resolve token + per-node data dirs"
  if [ -n "$CLI_TOK" ]; then NATS_AUTH_TOKEN="$CLI_TOK"; ok "token: set via --token"
  elif [ "$GEN_TOK" = 1 ] || [ -z "${NATS_AUTH_TOKEN:-}" ]; then NATS_AUTH_TOKEN="$(gen_pw)"; ok "token: auto-generated (24-char)"
  else ok "token: reused from .env"; fi
  set_env_var NATS_AUTH_TOKEN "$NATS_AUTH_TOKEN"
  set_env_var N_CLIENT1 "$N_CLIENT1"; set_env_var N_CLIENT2 "$N_CLIENT2"; set_env_var N_CLIENT3 "$N_CLIENT3"
  sudo mkdir -p "$CDIR"/n1 "$CDIR"/n2 "$CDIR"/n3; sudo chown -R 1000:1000 "$CDIR" 2>/dev/null || true

  step "2/3  docker compose up -d (3 nodes mesh via routes)"
  docker compose up -d
  for p in "$N_MON1" "$N_MON2" "$N_MON3"; do
    printf '   waiting for :%s/healthz' "$p"; local up=0
    for _ in $(seq 1 30); do [ "$(healthz "$p")" = 200 ] && { echo ' ✓'; up=1; break; }; printf '.'; sleep 2; done
    [ "$up" = 1 ] || warn "node mon :${p} not answering yet"
  done

  step "3/3  Verify the route mesh (each node sees 2 routes)"
  printf '   waiting for the mesh'; local r=0
  for _ in $(seq 1 20); do r="$(nroutes "$N_MON1")"; [ "${r:-0}" -ge 2 ] 2>/dev/null && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  ok "node1 routes: ${r:-0} (mesh of 3 => 2 each)"
  docker compose ps
  print_summary
  do_accept || warn "acceptance had warnings — see above"
}

do_accept(){
  step "Acceptance — 3-node mesh / JetStream R3 write-here-read-there / node-down failover"
  local rc=0 B="HACHK_$(date +%s)" K=rice V="চাল-rice"
  echo "== (1) route mesh: each node sees 2 routes =="
  local r1 r2 r3; r1="$(nroutes "$N_MON1")"; r2="$(nroutes "$N_MON2")"; r3="$(nroutes "$N_MON3")"
  echo "   routes: n1=${r1:-0} n2=${r2:-0} n3=${r3:-0}"
  { [ "${r1:-0}" -ge 2 ] && [ "${r2:-0}" -ge 2 ] && [ "${r3:-0}" -ge 2 ]; } 2>/dev/null && ok "all 3 nodes meshed" || { warn "mesh incomplete"; rc=1; }

  echo "== (2) JetStream R3 KV: write via node1, read via node2 + node3 =="
  # an R3 bucket can ONLY be created on a real 3-node JetStream cluster — its success proves the cluster.
  local w=0; for _ in $(seq 1 15); do na "$N_CLIENT1" kv add "$B" --replicas=3 --history=1 >/dev/null 2>&1 && { w=1; break; }; sleep 2; done
  [ "$w" = 1 ] && ok "created an R3 (replicas=3) KV bucket" || { warn "could not create R3 bucket"; rc=1; }
  na "$N_CLIENT1" kv put "$B" "$K" "$V" >/dev/null 2>&1
  local g2=0 g3=0
  for _ in $(seq 1 10); do [ "$(na "$N_CLIENT2" kv get "$B" "$K" --raw 2>/dev/null | tr -d '\r\n')" = "$V" ] && { g2=1; break; }; sleep 1; done
  for _ in $(seq 1 10); do [ "$(na "$N_CLIENT3" kv get "$B" "$K" --raw 2>/dev/null | tr -d '\r\n')" = "$V" ] && { g3=1; break; }; sleep 1; done
  [ "$g2" = 1 ] && ok "node2 reads the UTF-8 value written on node1" || { warn "node2 read mismatch"; rc=1; }
  [ "$g3" = 1 ] && ok "node3 reads the UTF-8 value written on node1" || { warn "node3 read mismatch"; rc=1; }

  echo "== (3) failover: stop nats3, KV still writable/readable (R3 quorum 2/3) =="
  docker compose stop nats3 >/dev/null 2>&1 || true; sleep 5
  local f=0; for _ in $(seq 1 12); do na "$N_CLIENT1" kv put "$B" "$K" "survived-$(date +%s)" >/dev/null 2>&1 && [ -n "$(na "$N_CLIENT2" kv get "$B" "$K" --raw 2>/dev/null)" ] && { f=1; break; }; sleep 2; done
  [ "$f" = 1 ] && ok "write+read succeeded with nats3 down" || { warn "failover write/read failed"; rc=1; }
  docker compose start nats3 >/dev/null 2>&1 || true
  local c=0; for _ in $(seq 1 20); do [ "$(nroutes "$N_MON1")" -ge 2 ] 2>/dev/null && [ "$(healthz "$N_MON3")" = 200 ] && { c=1; break; }; sleep 3; done
  [ "$c" = 1 ] && ok "nats3 re-joined the mesh" || warn "nats3 rejoin slow"

  na "$N_CLIENT1" kv rm "$B" -f >/dev/null 2>&1 || true
  [ "$rc" = 0 ] && ok "ACCEPTANCE PASS" || warn "ACCEPTANCE had failures"
  return "$rc"
}

do_down(){ docker compose down; echo "Containers removed. DATA PRESERVED at ${CDIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$CDIR"; echo "Full wipe: containers + ${CDIR} removed."; }
do_status(){ docker compose ps || true
  for p in "$N_MON1" "$N_MON2" "$N_MON3"; do echo "  mon :${p} healthz=$(healthz "$p") routes=$(nroutes "$p")"; done
  echo "data (host): ${CDIR} ($(sudo du -sh "$CDIR" 2>/dev/null | cut -f1 || echo absent))"; }
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
  accept)         do_accept ;;
  down|uninstall) do_down ;;
  purge)          do_purge ;;
  status)         do_status ;;
  logs)           do_logs ;;
  *) usage; exit 2 ;;
esac
