#!/usr/bin/env bash
# DOKANDAR utility — ScyllaDB 2026.1 · Docker Compose HA cluster (3 nodes, one ring). scylla1 seeds;
# scylla2/scylla3 join SERIALLY (depends_on service_healthy). Auto-runs the acceptance gate: nodetool shows
# 3 UN nodes; a keyspace at RF=3 written via node1 reads back via node2 AND node3; a node-down failover
# still serves. Per-node data = HOST bind mounts (survive `down -v`). No auth (CQL DB).
#   Usage:  bash setup.sh up | down | purge | status | accept | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${SCYLLA_IMAGE:=scylladb/scylla:2026.1}"
: "${SCY_CQL1:=9042}"; : "${SCY_CQL2:=9043}"; : "${SCY_CQL3:=9044}"
CDIR="${DATA_ROOT}/scylla_cluster"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up | down | purge | status | accept | logs"; }
# run CQL against the node on host port $1
cql(){ docker run --rm --network host --entrypoint cqlsh "$SCYLLA_IMAGE" 127.0.0.1 "$1" --request-timeout=25 -e "$2" 2>/dev/null; }
nun(){ docker exec dokandar_scylla_c1 nodetool status 2>/dev/null | grep -c '^UN' || true; }   # count UN nodes

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details"
  printf '%s' "$(_c '1;36')"; echo "===== ScyllaDB HA cluster (3-node ring) — connection details ====="; printf '%s' "$(_c 0)"
  cat <<SUM
  CQL endpoints  : ${host}:${SCY_CQL1} (n1), :${SCY_CQL2} (n2), :${SCY_CQL3} (n3)
                   one ring (cluster_name=${SCYLLA_CLUSTER_NAME:-dokandar}); use replication_factor=3 for HA
  Auth           : none (authenticator off by default)
  Browser UI     : none — N/A (CQL database; cqlsh / nodetool)
  Test from afar : SCYLLA_HOST=${host} SCYLLA_CQL_PORT=${SCY_CQL1} bash ../test.sh
  Data (host)    : ${CDIR}/n{1,2,3}   (bind mounts — survive 'down -v')
SUM
  printf '%s' "$(_c '1;36')"; echo "=================================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  step "1/3  Per-node data dirs + host AIO limit"
  sudo mkdir -p "$CDIR"/n1 "$CDIR"/n2 "$CDIR"/n3; sudo chown -R 999:999 "$CDIR" 2>/dev/null || true
  # 3 Scylla nodes share the HOST kernel's AIO contexts; the default fs.aio-max-nr is exhausted by the
  # first 2 nodes, so the 3rd fails seastar init ("does not satisfy minimum AIO requirements"). Raise it
  # (scylla_setup would do this natively; in dev-mode/docker we still need the host limit for >1 node).
  sudo sysctl -w fs.aio-max-nr=1048576 >/dev/null 2>&1 || true
  sudo sysctl -w fs.aio-nr >/dev/null 2>&1 || true
  ok "host fs.aio-max-nr = $(cat /proc/sys/fs/aio-max-nr 2>/dev/null || echo '?')"

  step "2/3  docker compose up -d (serial bootstrap: scylla1 -> scylla2 -> scylla3; slow)"
  docker compose up -d
  printf '   waiting for 3 UN nodes in the ring'; local n=0
  for _ in $(seq 1 80); do n="$(nun)"; [ "${n:-0}" = 3 ] && { echo ' ✓'; break; }; printf '.'; sleep 5; done
  ok "ring nodes UN: ${n:-0}/3"

  step "3/3  nodetool status"
  docker exec dokandar_scylla_c1 nodetool status 2>/dev/null | grep -E '^(UN|DN|Datacenter|=)' | sed 's/^/   /' || true
  docker compose ps
  print_summary
  do_accept || warn "acceptance had warnings — see above"
}

do_accept(){
  step "Acceptance — 3 UN nodes / RF=3 write-here-read-there / node-down failover"
  local rc=0 KS="ha_$(date +%s)"
  echo "== (1) ring has 3 UN nodes =="
  local n; n="$(nun)"
  [ "${n:-0}" = 3 ] && ok "3 nodes Up/Normal in the ring" || { warn "UN nodes=${n:-0}"; rc=1; }

  echo "== (2) keyspace RF=3: write via node1, read via node2 + node3 =="
  cql "$SCY_CQL1" "CREATE KEYSPACE ${KS} WITH replication = {'class':'SimpleStrategy','replication_factor':3};
USE ${KS}; CREATE TABLE t (id int PRIMARY KEY, name text);
INSERT INTO t (id,name) VALUES (1,'চাল-rice'); INSERT INTO t (id,name) VALUES (2,'ডিম-egg');" >/dev/null 2>&1
  local r2=0 r3=0
  for _ in $(seq 1 12); do [ "$(cql "$SCY_CQL2" "SELECT JSON count(*) FROM ${KS}.t;" | grep -oE '\{.*\}' | grep -oE '[0-9]+' | head -1)" = 2 ] && { r2=1; break; }; sleep 2; done
  for _ in $(seq 1 12); do [ "$(cql "$SCY_CQL3" "SELECT JSON count(*) FROM ${KS}.t;" | grep -oE '\{.*\}' | grep -oE '[0-9]+' | head -1)" = 2 ] && { r3=1; break; }; sleep 2; done
  [ "$r2" = 1 ] && ok "node2 returns the rows written on node1" || { warn "node2 read != 2"; rc=1; }
  [ "$r3" = 1 ] && ok "node3 returns the rows written on node1" || { warn "node3 read != 2"; rc=1; }
  [ "$(cql "$SCY_CQL2" "SELECT JSON name FROM ${KS}.t WHERE id=1;" | grep -oE '"name": *"[^"]*"' | sed -E 's/.*: *"//; s/"$//')" = "চাল-rice" ] && ok "UTF-8 value intact on node2" || { warn "node2 value mismatch"; rc=1; }

  echo "== (3) failover: stop scylla3, write+read still work (RF=3, quorum 2/3) =="
  docker compose stop scylla3 >/dev/null 2>&1 || true; sleep 6
  cql "$SCY_CQL1" "INSERT INTO ${KS}.t (id,name) VALUES (3,'মাছ-fish');" >/dev/null 2>&1
  local rr=0; for _ in $(seq 1 12); do [ "$(cql "$SCY_CQL2" "SELECT JSON count(*) FROM ${KS}.t;" | grep -oE '\{.*\}' | grep -oE '[0-9]+' | head -1)" = 3 ] && { rr=1; break; }; sleep 2; done
  [ "$rr" = 1 ] && ok "write+read succeeded with scylla3 down (node2 serves 3 rows)" || { warn "failover read != 3"; rc=1; }
  docker compose start scylla3 >/dev/null 2>&1 || true
  local c=0; for _ in $(seq 1 24); do [ "$(nun)" = 3 ] && { c=1; break; }; sleep 5; done
  [ "$c" = 1 ] && ok "scylla3 re-joined the ring (3 UN nodes)" || warn "scylla3 rejoin slow"

  cql "$SCY_CQL1" "DROP KEYSPACE IF EXISTS ${KS};" >/dev/null 2>&1 || true
  [ "$rc" = 0 ] && ok "ACCEPTANCE PASS" || warn "ACCEPTANCE had failures"
  return "$rc"
}

do_down(){ docker compose down; echo "Containers removed. DATA PRESERVED at ${CDIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$CDIR"; echo "Full wipe: containers + ${CDIR} removed."; }
do_status(){ docker compose ps || true; echo "  UN nodes: $(nun)/3"
  echo "data (host): ${CDIR} ($(sudo du -sh "$CDIR" 2>/dev/null | cut -f1 || echo absent))"; }
do_logs(){ docker compose logs --tail=80 -f; }

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  up|install)     do_up ;;
  accept)         do_accept ;;
  down|uninstall) do_down ;;
  purge)          do_purge ;;
  status)         do_status ;;
  logs)           do_logs ;;
  *) usage; exit 2 ;;
esac
