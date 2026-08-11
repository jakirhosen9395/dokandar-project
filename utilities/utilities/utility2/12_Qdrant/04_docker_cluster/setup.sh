#!/usr/bin/env bash
# DOKANDAR utility — Qdrant 1.18 · Docker Compose HA cluster (3 peers, one Raft consensus group).
# Auto-generates the API key, brings up q1 (--uri) + q2/q3 (--bootstrap), and runs the acceptance gate:
# every peer's GET /cluster shows 3 peers enabled; a sharded+replicated collection's points written via q1
# read back via q2 AND q3; and a node-down failover still serves the collection. Per-node storage = HOST
# bind mounts (survive `down -v`).
#   Usage:  bash setup.sh up [--gen-key|--key KEY] | down | purge | status | accept | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${Q_HTTP1:=6333}"; : "${Q_HTTP2:=6343}"; : "${Q_HTTP3:=6353}"; : "${Q_GRPC1:=6334}"
: "${QDRANT_SHARD_NUMBER:=3}"; : "${QDRANT_REPLICATION_FACTOR:=2}"
CDIR="${DATA_ROOT}/qdrant_cluster"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up [--gen-key|--key KEY] | down | purge | status | accept | logs"; }
gen_pw(){ local s; s="$(od -An -tx1 -N18 /dev/urandom | tr -dc 'a-f0-9')"; printf '%s' "${s:0:24}"; }  # SIGPIPE-safe
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true; export "${k}=${v}"
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }
# curl with a Docker fallback (no host packages needed for the cluster acceptance).
if command -v curl >/dev/null 2>&1; then CURL(){ curl "$@"; }
else docker image inspect curlimages/curl:latest >/dev/null 2>&1 || docker pull -q curlimages/curl:latest >/dev/null 2>&1 || true; CURL(){ docker run --rm -i --network host curlimages/curl:latest "$@"; }; fi
# REST call to a node by its published HTTP port. Args: <port> <method> <path> [body]
qa(){ local p="$1" m="$2" path="$3" b="${4:-}"
  if [ -n "$b" ]; then CURL -s --max-time 25 -H "api-key: ${QDRANT_API_KEY}" -X "$m" -H 'content-type: application/json' "http://127.0.0.1:${p}${path}" -d "$b"
  else CURL -s --max-time 25 -H "api-key: ${QDRANT_API_KEY}" -X "$m" "http://127.0.0.1:${p}${path}"; fi; }
pready(){ CURL -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${1}/readyz" 2>/dev/null || echo 000; }
npeers(){ qa "$1" GET /cluster 2>/dev/null | grep -oE '"uri":"[^"]*"' | sort -u | wc -l; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (API key shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "===== Qdrant HA cluster (3-peer Raft) — connection details ====="; printf '%s' "$(_c 0)"
  cat <<SUM
  REST endpoints : http://${host}:${Q_HTTP1} (q1), :${Q_HTTP2} (q2), :${Q_HTTP3} (q3)
                   no single primary — every peer accepts reads/writes (shards replicated by Raft)
  gRPC API       : ${host}:${Q_GRPC1} (q1)
  API key        : ${QDRANT_API_KEY}   (header: api-key: <key>; identical on all peers)
  Collections    : created with shard_number=${QDRANT_SHARD_NUMBER}, replication_factor=${QDRANT_REPLICATION_FACTOR}
  Browser UI     : http://${host}:${Q_HTTP1}/dashboard   (built-in — paste the key in Settings)
  Test from afar : QDRANT_HOST=${host} QDRANT_HTTP_PORT=${Q_HTTP1} QDRANT_API_KEY=${QDRANT_API_KEY} bash ../test.sh
  Data (host)    : ${CDIR}/n{1,2,3}   (bind mounts — survive 'down -v')
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "================================================================"; printf '%s' "$(_c 0)"
}

do_up(){
  step "1/3  Resolve API key + per-node data dirs"
  if [ -n "$CLI_KEY" ]; then QDRANT_API_KEY="$CLI_KEY"; ok "API key: set via --key"
  elif [ "$GEN_KEY" = 1 ] || [ -z "${QDRANT_API_KEY:-}" ]; then QDRANT_API_KEY="$(gen_pw)"; ok "API key: auto-generated (24-char)"
  else ok "API key: reused from .env"; fi
  set_env_var QDRANT_API_KEY "$QDRANT_API_KEY"
  set_env_var Q_HTTP1 "$Q_HTTP1"; set_env_var Q_HTTP2 "$Q_HTTP2"; set_env_var Q_HTTP3 "$Q_HTTP3"
  sudo mkdir -p "$CDIR"/n1 "$CDIR"/n2 "$CDIR"/n3

  step "2/3  docker compose up -d (q1 bootstraps, q2/q3 join via Raft)"
  docker compose up -d
  for p in "$Q_HTTP1" "$Q_HTTP2" "$Q_HTTP3"; do
    printf '   waiting for REST :%s' "$p"; local h=000
    for _ in $(seq 1 40); do h="$(pready "$p")"; [ "$h" = 200 ] && { echo ' ✓'; break; }; printf '.'; sleep 2; done
    [ "$h" = 200 ] || warn "peer on :${p} not answering yet"
  done

  step "3/3  Verify Raft consensus (3 peers on every node)"
  printf '   waiting for 3-peer consensus'; local n=0
  for _ in $(seq 1 30); do n="$(npeers "$Q_HTTP1")"; [ "${n:-0}" = 3 ] && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  ok "peers seen by q1: ${n:-0}/3"
  docker compose ps
  print_summary
  do_accept || warn "acceptance had warnings — see above"
}

do_accept(){
  step "Acceptance — 3 peers / sharded+replicated write-here-read-there / node-down failover"
  local rc=0 C="ha_$(date +%s)" qv='[0.9,0.1,0.0,0.0]'
  echo "== (1) every peer reports 3 peers, status enabled =="
  local p1 p2 p3; p1="$(npeers "$Q_HTTP1")"; p2="$(npeers "$Q_HTTP2")"; p3="$(npeers "$Q_HTTP3")"
  echo "   peers seen: q1=${p1} q2=${p2} q3=${p3}"
  { [ "$p1" = 3 ] && [ "$p2" = 3 ] && [ "$p3" = 3 ]; } && ok "all 3 peers agree on a 3-node consensus" || { warn "peer counts off"; rc=1; }

  echo "== (2) sharded+replicated collection: write via q1, read via q2 + q3 =="
  qa "$Q_HTTP1" PUT "/collections/${C}" "{\"vectors\":{\"size\":4,\"distance\":\"Dot\"},\"shard_number\":${QDRANT_SHARD_NUMBER},\"replication_factor\":${QDRANT_REPLICATION_FACTOR}}" >/dev/null 2>&1
  # wait for the collection metadata to replicate to q2 + q3 via Raft BEFORE writing points
  local e2=0 e3=0
  for _ in $(seq 1 15); do [ "$(qa "$Q_HTTP2" GET "/collections/${C}" | grep -oE '"status":"(green|yellow)"' | head -1 | grep -c status)" = 1 ] && { e2=1; break; }; sleep 1; done
  for _ in $(seq 1 15); do [ "$(qa "$Q_HTTP3" GET "/collections/${C}" | grep -oE '"status":"(green|yellow)"' | head -1 | grep -c status)" = 1 ] && { e3=1; break; }; sleep 1; done
  { [ "$e2" = 1 ] && [ "$e3" = 1 ]; } && ok "collection metadata replicated to q2 + q3 (Raft)" || { warn "collection not on q2/q3 (q2=${e2} q3=${e3})"; rc=1; }
  qa "$Q_HTTP1" PUT "/collections/${C}/points?wait=true" '{"points":[
    {"id":1,"vector":[0.9,0.1,0.0,0.0],"payload":{"name":"চাল-rice"}},
    {"id":2,"vector":[0.1,0.9,0.0,0.0],"payload":{"name":"ডিম-egg"}},
    {"id":3,"vector":[0.0,0.0,0.9,0.1],"payload":{"name":"মাছ-fish"}}]}' >/dev/null 2>&1
  local r2=0 r3=0
  for _ in $(seq 1 12); do [ "$(qa "$Q_HTTP2" POST "/collections/${C}/points/count" '{"exact":true}' | grep -oE '"count":[0-9]+' | head -1 | cut -d: -f2)" = 3 ] && { r2=1; break; }; sleep 1; done
  for _ in $(seq 1 12); do [ "$(qa "$Q_HTTP3" POST "/collections/${C}/points/count" '{"exact":true}' | grep -oE '"count":[0-9]+' | head -1 | cut -d: -f2)" = 3 ] && { r3=1; break; }; sleep 1; done
  [ "$r2" = 1 ] && ok "q2 returns the 3 points written on q1" || { warn "q2 count != 3"; rc=1; }
  [ "$r3" = 1 ] && ok "q3 returns the 3 points written on q1" || { warn "q3 count != 3"; rc=1; }
  [ "$(qa "$Q_HTTP2" GET "/collections/${C}/points/1" | grep -oE '"name":"[^"]*"' | head -1 | cut -d'"' -f4)" = "চাল-rice" ] && ok "UTF-8 payload intact on q2" || { warn "q2 payload mismatch"; rc=1; }

  echo "== (3) failover: stop q3, search still served via q1 (replication_factor=${QDRANT_REPLICATION_FACTOR}) =="
  docker compose stop q3 >/dev/null 2>&1 || true; sleep 4
  local top; top="$(qa "$Q_HTTP1" POST "/collections/${C}/points/search" "{\"vector\":${qv},\"limit\":1}" | grep -oE '"id":[0-9]+' | head -1 | cut -d: -f2)"
  [ "$top" = 1 ] && ok "search via q1 still returns the point with q3 down (top id=1)" || { warn "search failed with q3 down (got '${top}')"; rc=1; }
  docker compose start q3 >/dev/null 2>&1 || true
  local c=0; for _ in $(seq 1 20); do [ "$(npeers "$Q_HTTP1")" = 3 ] && { c=1; break; }; sleep 2; done
  [ "$c" = 1 ] && ok "q3 re-joined the consensus (3 peers)" || warn "q3 rejoin slow"

  qa "$Q_HTTP1" DELETE "/collections/${C}" >/dev/null 2>&1 || true
  [ "$rc" = 0 ] && ok "ACCEPTANCE PASS" || warn "ACCEPTANCE had failures"
  return "$rc"
}

do_down(){ docker compose down; echo "Containers removed. DATA PRESERVED at ${CDIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$CDIR"; echo "Full wipe: containers + ${CDIR} removed."; }
do_status(){ docker compose ps || true
  for p in "$Q_HTTP1" "$Q_HTTP2" "$Q_HTTP3"; do echo "  REST :${p} readyz -> $(pready "$p"); peers -> $(npeers "$p")"; done
  echo "data (host): ${CDIR} ($(sudo du -sh "$CDIR" 2>/dev/null | cut -f1 || echo absent))"; }
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
  accept)         do_accept ;;
  down|uninstall) do_down ;;
  purge)          do_purge ;;
  status)         do_status ;;
  logs)           do_logs ;;
  *) usage; exit 2 ;;
esac
