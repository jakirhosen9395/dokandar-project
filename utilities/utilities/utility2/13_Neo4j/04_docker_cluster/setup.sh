#!/usr/bin/env bash
# DOKANDAR utility — Neo4j 2026.x Enterprise (EVAL licence) · Docker Compose HA cluster (3 PRIMARY servers,
# autonomous clustering / Raft). Auto-generates the password, brings up the 3 primaries, and runs the
# acceptance gate: 3 servers in the cluster; a node written via the leader is readable on the other two
# (replication); a follower-down failover still serves the cluster. Per-node data = HOST bind mounts.
#   Usage:  bash setup.sh up [--password P|--gen-password] | down | purge | status | accept | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${NEO4J_USER:=neo4j}"
: "${N_HTTP1:=7474}"; : "${N_HTTP2:=7475}"; : "${N_HTTP3:=7476}"; : "${N_BOLT1:=7687}"; : "${N_BOLT2:=7688}"; : "${N_BOLT3:=7689}"
CDIR="${DATA_ROOT}/neo4j_cluster"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up [--password P|--gen-password] | down | purge | status | accept | logs"; }
gen_pw(){ local s; s="$(od -An -tx1 -N18 /dev/urandom | tr -dc 'a-f0-9')"; printf '%s' "${s:0:24}"; }  # SIGPIPE-safe, >=8
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true; export "${k}=${v}"
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }
# curl with a Docker fallback (no host packages needed for the cluster acceptance).
if command -v curl >/dev/null 2>&1; then CURL(){ curl "$@"; }
else docker image inspect curlimages/curl:latest >/dev/null 2>&1 || docker pull -q curlimages/curl:latest >/dev/null 2>&1 || true; CURL(){ docker run --rm -i --network host curlimages/curl:latest "$@"; }; fi
# run a Cypher statement against the node on host port $1; returns the JSON response.
hq(){ CURL -s --max-time 25 -u "${NEO4J_USER}:${NEO4J_PASSWORD}" -H 'content-type: application/json' "http://127.0.0.1:${1}/db/neo4j/tx/commit" -d "{\"statements\":[{\"statement\":\"$2\"}]}" 2>/dev/null; }
phttp(){ local h; h="$(CURL -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${1}/" 2>/dev/null || echo 000)"; { [ "$h" = 200 ] || [ "$h" = 303 ]; }; }
rownum(){ printf '%s' "$1" | grep -oE '"row":\[[0-9]+\]' | head -1 | grep -oE '[0-9]+'; }
# write statement $1 to whichever node is the leader (loops the 3 ports; success = empty "errors":[]).
write_leader(){ local p R; for p in "$N_HTTP1" "$N_HTTP2" "$N_HTTP3"; do R="$(hq "$p" "$1")"; printf '%s' "$R" | grep -q '"errors":\[\]' && { printf '%s' "$p"; return 0; }; done; return 1; }
# the `neo4j` database is allocated/onlined a beat AFTER the servers join — gate writes on it being online
# somewhere (a clean read with empty errors proves the db is queryable). Same readiness class as ClickHouse Keeper/DDL.
db_online(){ local p; for p in "$N_HTTP1" "$N_HTTP2" "$N_HTTP3"; do hq "$p" "RETURN 1" | grep -q '"row":\[1\]' && return 0; done; return 1; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (password shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "===== Neo4j HA cluster (3 primaries, Enterprise EVAL) — connection details ====="; printf '%s' "$(_c 0)"
  cat <<SUM
  HTTP / Browser : http://${host}:${N_HTTP1} (n1), :${N_HTTP2} (n2), :${N_HTTP3} (n3)
                   writes route to the elected leader; every primary holds a full copy (Raft)
  Bolt endpoints : bolt://${host}:${N_BOLT1} (n1), :${N_BOLT2} (n2), :${N_BOLT3} (n3)
  Username       : ${NEO4J_USER}
  Password       : ${NEO4J_PASSWORD}   (identical on all 3 primaries)
  Test from afar : NEO4J_HOST=${host} NEO4J_HTTP_PORT=${N_HTTP1} NEO4J_USER=${NEO4J_USER} NEO4J_PASSWORD=${NEO4J_PASSWORD} bash ../test.sh
  Data (host)    : ${CDIR}/n{1,2,3}   (bind mounts — survive 'down -v')
  Licence        : Enterprise EVALUATION (NEO4J_ACCEPT_LICENSE_AGREEMENT=eval) — dev/test only
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "==============================================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  step "1/3  Resolve credentials + per-node data dirs"
  if [ -n "$CLI_PW" ]; then NEO4J_PASSWORD="$CLI_PW"; ok "password: set via --password"
  elif [ "$GEN_PW" = 1 ] || [ -z "${NEO4J_PASSWORD:-}" ]; then NEO4J_PASSWORD="$(gen_pw)"; ok "password: auto-generated (24-char)"
  else ok "password: reused from .env"; fi
  set_env_var NEO4J_USER "$NEO4J_USER"; set_env_var NEO4J_PASSWORD "$NEO4J_PASSWORD"
  set_env_var N_HTTP1 "$N_HTTP1"; set_env_var N_HTTP2 "$N_HTTP2"; set_env_var N_HTTP3 "$N_HTTP3"
  sudo mkdir -p "$CDIR"/n1 "$CDIR"/n2 "$CDIR"/n3; sudo chown -R 7474:7474 "$CDIR" 2>/dev/null || true

  step "2/3  docker compose up -d (3 primaries form one Raft group — Enterprise startup is slow)"
  docker compose up -d
  for p in "$N_HTTP1" "$N_HTTP2" "$N_HTTP3"; do
    printf '   waiting for HTTP :%s' "$p"; local up=0
    for _ in $(seq 1 60); do phttp "$p" && { echo ' ✓'; up=1; break; }; printf '.'; sleep 3; done
    [ "$up" = 1 ] || warn "node on :${p} not answering yet"
  done

  step "3/3  Verify cluster membership (3 servers)"
  printf '   waiting for 3-server cluster'; local n=0
  for _ in $(seq 1 40); do n="$(rownum "$(hq "$N_HTTP1" "SHOW SERVERS YIELD name RETURN count(name)")")"; [ "${n:-0}" = 3 ] && { echo ' ✓'; break; }; printf '.'; sleep 3; done
  ok "cluster servers: ${n:-0}/3"
  docker compose ps
  print_summary
  do_accept || warn "acceptance had warnings — see above"
}

do_accept(){
  step "Acceptance — 3 servers / write-leader-read-replicas / follower-down failover"
  local rc=0 L="HaCheck_$(date +%s)" lp
  echo "== (1) cluster has 3 servers =="
  local n; n="$(rownum "$(hq "$N_HTTP1" "SHOW SERVERS YIELD name RETURN count(name)")")"
  [ "${n:-0}" = 3 ] && ok "3 servers in the cluster" || { warn "servers=${n:-0}"; rc=1; }

  echo "== (2) write via the leader, read on all 3 primaries (replication) =="
  # wait for the neo4j db to be online + writable, then retry the write across the ports (the leader can
  # take a beat to elect after SHOW SERVERS reports 3) — a single pass can spuriously miss all three.
  local w=0; for _ in $(seq 1 20); do db_online && lp="$(write_leader "CREATE (:${L} {id:1, name:'চাল-rice'})")" && { w=1; break; }; sleep 3; done
  [ "$w" = 1 ] && ok "write accepted by the leader (:${lp})" || { warn "no node accepted the write"; rc=1; }
  local r1=0 r2=0 r3=0
  for _ in $(seq 1 15); do [ "$(rownum "$(hq "$N_HTTP1" "MATCH (n:${L}) RETURN count(n)")")" = 1 ] && { r1=1; break; }; sleep 1; done
  for _ in $(seq 1 15); do [ "$(rownum "$(hq "$N_HTTP2" "MATCH (n:${L}) RETURN count(n)")")" = 1 ] && { r2=1; break; }; sleep 1; done
  for _ in $(seq 1 15); do [ "$(rownum "$(hq "$N_HTTP3" "MATCH (n:${L}) RETURN count(n)")")" = 1 ] && { r3=1; break; }; sleep 1; done
  { [ "$r1" = 1 ] && [ "$r2" = 1 ] && [ "$r3" = 1 ]; } && ok "all 3 primaries replicated the node (n1=${r1} n2=${r2} n3=${r3})" || { warn "replication incomplete (n1=${r1} n2=${r2} n3=${r3})"; rc=1; }
  [ "$(printf '%s' "$(hq "$N_HTTP2" "MATCH (n:${L} {id:1}) RETURN n.name")" | grep -oE '"row":\["[^"]*"\]')" = '"row":["চাল-rice"]' ] && ok "UTF-8 property intact on n2" || { warn "n2 value mismatch"; rc=1; }

  echo "== (3) failover: stop neo4j3, write still accepted, read on the survivors (quorum 2/3) =="
  docker compose stop neo4j3 >/dev/null 2>&1 || true; sleep 6
  local w=0; for _ in $(seq 1 15); do write_leader "CREATE (:${L} {id:2, name:'ডিম-egg'})" >/dev/null && { w=1; break; }; sleep 2; done
  [ "$w" = 1 ] && ok "write accepted with neo4j3 down (re-election ok)" || { warn "write failed with neo4j3 down"; rc=1; }
  local rr=0; for _ in $(seq 1 15); do [ "$(rownum "$(hq "$N_HTTP1" "MATCH (n:${L}) RETURN count(n)")")" = 2 ] && { rr=1; break; }; sleep 1; done
  [ "$rr" = 1 ] && ok "survivors serve the full data (2 nodes) with neo4j3 down" || { warn "survivor read != 2"; rc=1; }
  docker compose start neo4j3 >/dev/null 2>&1 || true
  local c=0; for _ in $(seq 1 25); do [ "$(rownum "$(hq "$N_HTTP1" "SHOW SERVERS YIELD name RETURN count(name)")")" = 3 ] && { c=1; break; }; sleep 3; done
  [ "$c" = 1 ] && ok "neo4j3 re-joined the cluster (3 servers)" || warn "neo4j3 rejoin slow"

  write_leader "MATCH (n:${L}) DETACH DELETE n" >/dev/null 2>&1 || true
  [ "$rc" = 0 ] && ok "ACCEPTANCE PASS" || warn "ACCEPTANCE had failures"
  return "$rc"
}

do_down(){ docker compose down; echo "Containers removed. DATA PRESERVED at ${CDIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$CDIR"; echo "Full wipe: containers + ${CDIR} removed."; }
do_status(){ docker compose ps || true
  for p in "$N_HTTP1" "$N_HTTP2" "$N_HTTP3"; do phttp "$p" && echo "  HTTP :${p} -> OK" || echo "  HTTP :${p} -> DOWN"; done
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
