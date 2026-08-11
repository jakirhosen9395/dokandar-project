#!/usr/bin/env bash
# DOKANDAR utility — ClickHouse 26.3 LTS · Docker Compose HA cluster (1 shard x 3 replicas + embedded
# 3-node Keeper). Auto-generates the password, RENDERS per-node config (keeper server_id + replica macro +
# remote_servers + zookeeper + memory caps), brings up all 3 nodes, and runs the acceptance gate:
# cluster membership=3, ReplicatedMergeTree write-ch1/read-ch2+ch3, replicas healthy, node-down failover.
# Per-node config + data are HOST bind mounts (data survives `down -v`).
#   Usage:  bash setup.sh up [--user U] [--gen-password|--password P] | down | purge | status | accept | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${CLICKHOUSE_USER:=default}"
: "${CH_HTTP1:=8123}"; : "${CH_HTTP2:=8124}"; : "${CH_HTTP3:=8125}"; : "${CH_TCP1:=9000}"
: "${CH_CLUSTER:=dokandar_1S_3R}"
CDIR="${DATA_ROOT}/clickhouse_cluster"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up [--user U] [--gen-password|--password P] | down | purge | status | accept | logs"; }
gen_pw(){ local s; s="$(od -An -tx1 -N18 /dev/urandom | tr -dc 'a-f0-9')"; printf '%s' "${s:0:24}"; }  # SIGPIPE-safe
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true; export "${k}=${v}"
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }
# curl with a Docker fallback (no host packages needed for the read/write-split acceptance).
if command -v curl >/dev/null 2>&1; then CURL(){ curl "$@"; }
else docker image inspect curlimages/curl:latest >/dev/null 2>&1 || docker pull -q curlimages/curl:latest >/dev/null 2>&1 || true; CURL(){ docker run --rm -i --network host curlimages/curl:latest "$@"; }; fi
# query a node by its published HTTP port. Args: <port> <sql>
chq(){ printf '%s' "$2" | CURL -s --max-time 25 -u "${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}" "http://127.0.0.1:${1}/" --data-binary @- 2>/dev/null; }
phttp(){ CURL -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${1}/ping" 2>/dev/null || echo 000; }
# REAL Keeper-readiness probe: system.zookeeper ERRORS unless a live Keeper session exists (unlike
# system.clusters, which is config-only and returns 3 the instant the XML parses). 0 = not ready yet.
keeper_ready(){ local r; r="$(chq "$CH_HTTP1" "SELECT count() FROM system.zookeeper WHERE path='/'")"; case "$r" in ''|*[!0-9]*) return 1;; *) [ "$r" -ge 1 ];; esac; }
# does table $2 exist (in default) on the node at port $1?  -> "1" / "0"
texists(){ chq "$1" "SELECT count() FROM system.tables WHERE database='default' AND name='$2'"; }

# Render the full config.d/users.d for node $1 (server_id) with replica macro ch$1, into $CDIR/n$1.
render_node(){ local n="$1" nd="$CDIR/n$1"
  sudo mkdir -p "$nd/config.d" "$nd/users.d" "$nd/data"
  sudo tee "$nd/config.d/00-network.xml" >/dev/null <<'XML'
<clickhouse>
    <listen_host>0.0.0.0</listen_host>
    <http_port>8123</http_port>
    <tcp_port>9000</tcp_port>
    <interserver_http_port>9009</interserver_http_port>
</clickhouse>
XML
  # memory caps so 3 servers + 3 keepers fit one box; DON'T touch background_pool_size (default 16 is safe;
  # lowering it to 4 crash-loops the server — Code 36, pool < merge_tree reservation thresholds).
  sudo tee "$nd/config.d/01-memory.xml" >/dev/null <<'XML'
<clickhouse>
    <max_server_memory_usage>1500000000</max_server_memory_usage>
    <mark_cache_size>268435456</mark_cache_size>
</clickhouse>
XML
  sudo tee "$nd/config.d/10-keeper.xml" >/dev/null <<XML
<clickhouse>
    <keeper_server>
        <tcp_port>9181</tcp_port>
        <server_id>${n}</server_id>
        <log_storage_path>/var/lib/clickhouse/coordination/log</log_storage_path>
        <snapshot_storage_path>/var/lib/clickhouse/coordination/snapshots</snapshot_storage_path>
        <coordination_settings>
            <operation_timeout_ms>10000</operation_timeout_ms>
            <session_timeout_ms>30000</session_timeout_ms>
        </coordination_settings>
        <raft_configuration>
            <server><id>1</id><hostname>ch1</hostname><port>9234</port></server>
            <server><id>2</id><hostname>ch2</hostname><port>9234</port></server>
            <server><id>3</id><hostname>ch3</hostname><port>9234</port></server>
        </raft_configuration>
    </keeper_server>
</clickhouse>
XML
  sudo tee "$nd/config.d/20-zookeeper.xml" >/dev/null <<'XML'
<clickhouse>
    <zookeeper>
        <node><host>ch1</host><port>9181</port></node>
        <node><host>ch2</host><port>9181</port></node>
        <node><host>ch3</host><port>9181</port></node>
    </zookeeper>
</clickhouse>
XML
  sudo tee "$nd/config.d/30-remote-servers.xml" >/dev/null <<XML
<clickhouse>
    <remote_servers>
        <${CH_CLUSTER}>
            <shard>
                <internal_replication>true</internal_replication>
                <replica><host>ch1</host><port>9000</port></replica>
                <replica><host>ch2</host><port>9000</port></replica>
                <replica><host>ch3</host><port>9000</port></replica>
            </shard>
        </${CH_CLUSTER}>
    </remote_servers>
</clickhouse>
XML
  sudo tee "$nd/config.d/40-macros.xml" >/dev/null <<XML
<clickhouse>
    <macros>
        <shard>01</shard>
        <replica>ch${n}</replica>
        <cluster>${CH_CLUSTER}</cluster>
    </macros>
</clickhouse>
XML
  sudo tee "$nd/users.d/dokandar-password.xml" >/dev/null <<XML
<clickhouse>
    <users>
        <${CLICKHOUSE_USER}>
            <password>${CLICKHOUSE_PASSWORD}</password>
            <access_management>1</access_management>
        </${CLICKHOUSE_USER}>
    </users>
</clickhouse>
XML
  sudo chown -R 101:101 "$nd/data" 2>/dev/null || true
}

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (password shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "===== ClickHouse HA cluster (1 shard x 3 replicas + Keeper) — connection details ====="; printf '%s' "$(_c 0)"
  cat <<SUM
  HTTP endpoints : http://${host}:${CH_HTTP1} (ch1), :${CH_HTTP2} (ch2), :${CH_HTTP3} (ch3)
                   every node is a full replica — any node serves reads/writes (ReplicatedMergeTree)
  Native TCP     : ${host}:${CH_TCP1} (ch1)
  Cluster name   : ${CH_CLUSTER}   (1 shard, 3 replicas; macros {shard}=01 {replica}=chN)
  Username       : ${CLICKHOUSE_USER}
  Password       : ${CLICKHOUSE_PASSWORD}
  Browser UI     : http://${host}:${CH_HTTP1}/play   (built-in SQL console — same data on any node)
  Test from afar : CLICKHOUSE_HOST=${host} CLICKHOUSE_HTTP_PORT=${CH_HTTP1} CLICKHOUSE_USER=${CLICKHOUSE_USER} CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD} bash ../test.sh
  Data (host)    : ${CDIR}/n{1,2,3}/data   (bind mounts — survive 'down -v')
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "====================================================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  step "1/4  Resolve credentials"
  if [ -n "$CLI_PW" ]; then CLICKHOUSE_PASSWORD="$CLI_PW"; ok "password: set via --password"
  elif [ "$GEN_PW" = 1 ] || [ -z "${CLICKHOUSE_PASSWORD:-}" ]; then CLICKHOUSE_PASSWORD="$(gen_pw)"; ok "password: auto-generated (24-char)"
  else ok "password: reused from .env"; fi
  set_env_var CLICKHOUSE_USER "$CLICKHOUSE_USER"; set_env_var CLICKHOUSE_PASSWORD "$CLICKHOUSE_PASSWORD"
  set_env_var CH_HTTP1 "$CH_HTTP1"; set_env_var CH_HTTP2 "$CH_HTTP2"; set_env_var CH_HTTP3 "$CH_HTTP3"

  step "2/4  Render per-node config (keeper id + replica macro + remote_servers + zookeeper)"
  render_node 1; render_node 2; render_node 3; ok "configs written under ${CDIR}/n{1,2,3}"

  step "3/4  docker compose up -d (3 replicas + 3-node Keeper quorum)"
  docker compose up -d
  for p in "$CH_HTTP1" "$CH_HTTP2" "$CH_HTTP3"; do
    printf '   waiting for HTTP :%s' "$p"; local h=000
    for _ in $(seq 1 40); do h="$(phttp "$p")"; [ "$h" = 200 ] && { echo ' ✓'; break; }; printf '.'; sleep 2; done
    [ "$h" = 200 ] || warn "node on :${p} not answering yet"
  done

  step "4/4  Verify Keeper quorum + cluster membership"
  # gate on a REAL Keeper-ready signal (not the config-only system.clusters) before any ON CLUSTER DDL.
  printf '   waiting for Keeper quorum'; local kok=0
  for _ in $(seq 1 40); do keeper_ready && { echo ' ✓'; kok=1; break; }; printf '.'; sleep 2; done
  [ "$kok" = 1 ] && ok "Keeper quorum formed (system.zookeeper live)" || warn "Keeper not ready yet — DDL may race"
  local m; m="$(chq "$CH_HTTP1" "SELECT count() FROM system.clusters WHERE cluster='${CH_CLUSTER}'")"
  ok "cluster '${CH_CLUSTER}' members (config): ${m:-0}/3"
  docker compose ps
  print_summary
  do_accept || warn "acceptance had warnings — see above"
}

do_accept(){
  step "Acceptance — membership / replicated write-here-read-there / replicas healthy / failover"
  local rc=0 T="ha_$(date +%s)" V
  echo "== (1) Keeper quorum + cluster membership =="
  local kok=0; for _ in $(seq 1 20); do keeper_ready && { kok=1; break; }; sleep 2; done
  [ "$kok" = 1 ] && ok "Keeper quorum live (system.zookeeper)" || { warn "Keeper not ready"; rc=1; }
  local m; m="$(chq "$CH_HTTP1" "SELECT count() FROM system.clusters WHERE cluster='${CH_CLUSTER}'")"
  [ "${m:-0}" = 3 ] && ok "3 replicas in ${CH_CLUSTER} (config)" || { warn "members=${m:-0}"; rc=1; }

  echo "== (2) ReplicatedMergeTree: create ON CLUSTER, write ch1, read ch2 + ch3 =="
  # capture the ON CLUSTER status (one row per node) — a partial apply must be visible, not swallowed.
  local DDL; DDL="$(chq "$CH_HTTP1" "CREATE TABLE IF NOT EXISTS default.${T} ON CLUSTER ${CH_CLUSTER} (id UInt64, name String) ENGINE=ReplicatedMergeTree('/clickhouse/tables/{shard}/${T}','{replica}') ORDER BY id")"
  printf '%s\n' "$DDL" | grep -qiE 'exception|error' && { warn "ON CLUSTER DDL reported an error:"; printf '%s\n' "$DDL" | head -4 | sed 's/^/      /'; rc=1; }
  # assert the table PROPAGATED to ch2 + ch3 (distributed-DDL via Keeper) BEFORE polling rows — this
  # discriminates "DDL didn't propagate" from "rows not yet replicated".
  local e2=0 e3=0
  for _ in $(seq 1 15); do [ "$(texists "$CH_HTTP2" "$T")" = 1 ] && { e2=1; break; }; sleep 1; done
  for _ in $(seq 1 15); do [ "$(texists "$CH_HTTP3" "$T")" = 1 ] && { e3=1; break; }; sleep 1; done
  { [ "$e2" = 1 ] && [ "$e3" = 1 ]; } && ok "table propagated ON CLUSTER to ch2 + ch3" || { warn "DDL did not propagate (ch2=${e2} ch3=${e3})"; rc=1; }
  chq "$CH_HTTP1" "INSERT INTO default.${T} VALUES (1,'চাল-rice'),(2,'ডিম-egg')" >/dev/null 2>&1
  local r2=0 r3=0
  for _ in $(seq 1 10); do [ "$(chq "$CH_HTTP2" "SELECT count() FROM default.${T}")" = 2 ] && { r2=1; break; }; sleep 1; done
  for _ in $(seq 1 10); do [ "$(chq "$CH_HTTP3" "SELECT count() FROM default.${T}")" = 2 ] && { r3=1; break; }; sleep 1; done
  [ "$r2" = 1 ] && ok "ch2 replicated the rows written on ch1" || { warn "ch2 did not replicate"; rc=1; }
  [ "$r3" = 1 ] && ok "ch3 replicated the rows written on ch1" || { warn "ch3 did not replicate"; rc=1; }
  [ "$(chq "$CH_HTTP2" "SELECT name FROM default.${T} WHERE id=1")" = "চাল-rice" ] && ok "UTF-8 value intact on ch2" || { warn "ch2 value mismatch"; rc=1; }

  echo "== (3) replicas healthy (is_readonly=0, total=active=3) =="
  V="$(chq "$CH_HTTP1" "SELECT is_readonly, total_replicas, active_replicas FROM system.replicas WHERE table='${T}'")"
  echo "   ch1 system.replicas: ${V//$'\t'/ }"
  echo "$V" | grep -qE '^0[[:space:]]+3[[:space:]]+3' && ok "replica healthy (rw, 3/3 active)" || { warn "replica state: ${V}"; rc=1; }

  echo "== (4) failover: stop ch3, write ch1, read ch2; recover ch3 =="
  docker compose stop ch3 >/dev/null 2>&1 || true; sleep 4
  chq "$CH_HTTP1" "INSERT INTO default.${T} VALUES (3,'মাছ-fish')" >/dev/null 2>&1
  local r=0; for _ in $(seq 1 10); do [ "$(chq "$CH_HTTP2" "SELECT count() FROM default.${T}")" = 3 ] && { r=1; break; }; sleep 1; done
  [ "$r" = 1 ] && ok "write succeeded with ch3 down, ch2 served the read (3 rows)" || { warn "failover write/read failed"; rc=1; }
  docker compose start ch3 >/dev/null 2>&1 || true
  local c=0; for _ in $(seq 1 20); do [ "$(chq "$CH_HTTP3" "SELECT count() FROM default.${T}")" = 3 ] && { c=1; break; }; sleep 2; done
  [ "$c" = 1 ] && ok "ch3 caught up after restart (3 rows)" || warn "ch3 catch-up slow"

  chq "$CH_HTTP1" "DROP TABLE IF EXISTS default.${T} ON CLUSTER ${CH_CLUSTER} SYNC" >/dev/null 2>&1 || true
  [ "$rc" = 0 ] && ok "ACCEPTANCE PASS" || warn "ACCEPTANCE had failures"
  return "$rc"
}

do_down(){ docker compose down; echo "Containers removed. DATA PRESERVED at ${CDIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$CDIR"; echo "Full wipe: containers + ${CDIR} removed."; }
do_status(){ docker compose ps || true
  for p in "$CH_HTTP1" "$CH_HTTP2" "$CH_HTTP3"; do echo "  HTTP :${p} ping -> $(phttp "$p")"; done
  echo "data (host): ${CDIR} ($(sudo du -sh "$CDIR" 2>/dev/null | cut -f1 || echo absent))"; }
do_logs(){ docker compose logs --tail=80 -f; }

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
GEN_PW=0; CLI_PW=""                                # parse flags AFTER the subcommand is stripped
while [ $# -gt 0 ]; do case "$1" in
  --user) CLICKHOUSE_USER="$2"; shift 2;;
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
