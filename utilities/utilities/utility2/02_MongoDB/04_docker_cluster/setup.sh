#!/usr/bin/env bash
# DOKANDAR utility — MongoDB · Docker Compose SHARDED CLUSTER (mongos + config-RS + 2 shards each a replica set).
# Auto-generates the keyFile + root password, initiates the config-RS and both shard replica sets, creates the
# root user (mongos localhost exception), adds both shards, shards a sample collection, and runs the acceptance:
# 2 shards online, data written via mongos DISTRIBUTES across shards, per-shard primary→secondary replication,
# read/write split (write→primary, secondary-read via readPreference). Per-component data are HOST bind mounts.
#   Usage:  bash setup.sh up [--password P|--gen-password] | down | purge | status | accept | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${MONGO_VERSION:=7.0}"; : "${MONGOS_PORT:=27017}"; : "${MONGO_ROOT_USER:=dokandar}"
: "${KEYFILE_HOST_PATH:=${DATA_ROOT}/mongodb_sharded/keyfile}"
CDIR="${DATA_ROOT}/mongodb_sharded"; SHARD_DB="${SHARD_DB:-dokandar}"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up [--password P|--gen-password] | down | purge | status | accept | logs"; }
genpw(){ local s; s="$(od -An -tx1 -N18 /dev/urandom | tr -dc 'a-f0-9')"; printf '%s' "${s:0:24}"; }  # SIGPIPE-safe
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true; export "${k}=${v}"
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }
# mongosh inside a container; localhost exception (no auth) vs authed.
mnoauth(){ docker exec "dokandar_mongo_$1" mongosh --quiet --port 27017 --eval "$2" 2>/dev/null; }
mauth(){ docker exec "dokandar_mongo_$1" mongosh --quiet --port 27017 -u "$MONGO_ROOT_USER" -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin --eval "$2" 2>/dev/null; }
wait_primary(){ local c="$1"; for _ in $(seq 1 30); do [ "$(mnoauth "$c" 'db.hello().isWritablePrimary' 2>/dev/null)" = true ] && return 0; sleep 2; done; return 1; }
ping_up(){ local c="$1"; for _ in $(seq 1 40); do mnoauth "$c" 'db.runCommand({ping:1}).ok' 2>/dev/null | grep -q 1 && return 0; sleep 2; done; return 1; }

GEN=0; CLI_PW=""

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (password shown ONCE — copy it into your test env)"
  printf '%s' "$(_c '1;36')"; echo "===== MongoDB sharded cluster (mongos + config-RS + 2 shards) — connection details ====="; printf '%s' "$(_c 0)"
  cat <<SUM
  mongos (router)  : ${host}:${MONGOS_PORT}   (the single client entry point — all reads/writes go here)
  Connection URI   : mongodb://${MONGO_ROOT_USER}:${MONGO_ROOT_PASSWORD}@${host}:${MONGOS_PORT}/?authSource=admin
  Username / pass  : ${MONGO_ROOT_USER} / ${MONGO_ROOT_PASSWORD}   (root)
  Topology         : config-RS csrs (cfg1) · shard rs-shard1 (s1a+s1b) · shard rs-shard2 (s2a+s2b)
  Sharded sample   : ${SHARD_DB}.items (hashed _id) — writes distribute; secondary reads via readPreference
  Browser UI       : none — N/A (use mongosh / Compass against mongos)
  Test from afar   : bash ../test.sh "mongodb://${MONGO_ROOT_USER}:${MONGO_ROOT_PASSWORD}@${host}:${MONGOS_PORT}/?authSource=admin"
  Data (host)      : ${CDIR}/{cfg1,s1a,s1b,s2a,s2b}   (bind mounts — survive 'down -v')
  Saved to         : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "========================================================================================"; printf '%s' "$(_c 0)"
}

do_up(){
  step "1/6  Resolve password + keyFile + data dirs"
  [ -n "$CLI_PW" ] && MONGO_ROOT_PASSWORD="$CLI_PW"
  if [ "$GEN" = 1 ] || [ -z "${MONGO_ROOT_PASSWORD:-}" ]; then MONGO_ROOT_PASSWORD="$(genpw)"; ok "root password: generated (24-char)"; else ok "root password: reused"; fi
  set_env_var MONGO_ROOT_USER "$MONGO_ROOT_USER"; set_env_var MONGO_ROOT_PASSWORD "$MONGO_ROOT_PASSWORD"; set_env_var MONGOS_PORT "$MONGOS_PORT"
  sudo mkdir -p "$(dirname "$KEYFILE_HOST_PATH")" "$CDIR"/cfg1 "$CDIR"/s1a "$CDIR"/s1b "$CDIR"/s2a "$CDIR"/s2b
  if [ ! -s "$KEYFILE_HOST_PATH" ]; then openssl rand -base64 756 | sudo tee "$KEYFILE_HOST_PATH" >/dev/null; fi
  sudo chmod 400 "$KEYFILE_HOST_PATH"; sudo chown 999:999 "$KEYFILE_HOST_PATH" "$CDIR"/cfg1 "$CDIR"/s1a "$CDIR"/s1b "$CDIR"/s2a "$CDIR"/s2b 2>/dev/null || true
  ok "keyFile ${KEYFILE_HOST_PATH} (400, uid 999); data dirs ready"

  step "2/6  Start the config server + shard mongods (NOT mongos yet)"
  docker compose up -d cfg1 s1a s1b s2a s2b
  for c in cfg1 s1a s2a; do printf '   waiting for %s' "$c"; ping_up "$c" && echo ' ✓' || warn "$c not up"; done

  step "3/6  Initiate the config replica set + both shard replica sets"
  mnoauth cfg1 "rs.initiate({_id:'csrs',configsvr:true,members:[{_id:0,host:'cfg1:27017'}]})" >/dev/null 2>&1 || true
  # priority:2 on member 0 (s1a/s2a) → it is deterministically elected PRIMARY, so the createUser below
  # (and the acceptance's direct-shard queries) always hit the primary in these 2-member shard replica sets.
  mnoauth s1a "rs.initiate({_id:'rs-shard1',members:[{_id:0,host:'s1a:27017',priority:2},{_id:1,host:'s1b:27017'}]})" >/dev/null 2>&1 || true
  mnoauth s2a "rs.initiate({_id:'rs-shard2',members:[{_id:0,host:'s2a:27017',priority:2},{_id:1,host:'s2b:27017'}]})" >/dev/null 2>&1 || true
  printf '   waiting for primaries'; for c in cfg1 s1a s2a; do wait_primary "$c" >/dev/null 2>&1 && printf ' %s✓' "$c" || printf ' %s✗' "$c"; done; echo
  # A shard-local root user on each shard primary (replicates to its secondary) so the acceptance can query
  # shards DIRECTLY — the cluster root user (created via mongos, step 4) lives only on the config servers.
  for c in s1a s2a; do mnoauth "$c" "db.getSiblingDB('admin').createUser({user:'${MONGO_ROOT_USER}',pwd:'${MONGO_ROOT_PASSWORD}',roles:[{role:'root',db:'admin'}]})" >/dev/null 2>&1 || true; done
  ok "config-RS + 2 shard RSs initiated (shard-local admin users created)"

  step "4/6  Start mongos + create the root user (localhost exception)"
  docker compose up -d mongos; printf '   waiting for mongos'; ping_up mongos && echo ' ✓' || warn "mongos not up"
  mnoauth mongos "db.getSiblingDB('admin').createUser({user:'${MONGO_ROOT_USER}',pwd:'${MONGO_ROOT_PASSWORD}',roles:[{role:'root',db:'admin'}]})" >/dev/null 2>&1 \
    && ok "root user created via mongos" || warn "root user create skipped (already exists?)"

  step "5/6  Add both shards + shard a sample collection"
  mauth mongos "sh.addShard('rs-shard1/s1a:27017,s1b:27017'); sh.addShard('rs-shard2/s2a:27017,s2b:27017')" >/dev/null 2>&1 || true
  mauth mongos "sh.enableSharding('${SHARD_DB}'); db.getSiblingDB('${SHARD_DB}').createCollection('items'); sh.shardCollection('${SHARD_DB}.items',{_id:'hashed'})" >/dev/null 2>&1 || true
  local ns; ns="$(mauth mongos "db.getSiblingDB('config').shards.countDocuments({})")"
  ok "shards in the cluster: ${ns:-?}/2 ; ${SHARD_DB}.items sharded (hashed _id)"

  step "6/6  Done"
  docker compose ps
  print_summary
  do_accept || warn "acceptance had warnings — see above"
}

do_accept(){
  step "Acceptance — 2 shards / write-distributes / per-shard replication / read-write split"
  local rc=0
  echo "== (1) 2 shards online =="
  local ns; ns="$(mauth mongos "db.getSiblingDB('config').shards.countDocuments({})")"
  [ "${ns:-0}" = 2 ] && ok "2 shards registered in the cluster" || { warn "shards=${ns:-0}"; rc=1; }

  echo "== (2) write 200 docs via mongos → they DISTRIBUTE across both shards =="
  mauth mongos "var b=db.getSiblingDB('${SHARD_DB}').items.initializeUnorderedBulkOp(); for(var i=0;i<200;i++){b.insert({_id:i,v:'চাল-'+i})}; b.execute()" >/dev/null 2>&1
  # per-shard physical counts (each shard's primary) — both should hold a slice of the 200 hashed docs.
  local c1 c2; c1="$(mauth s1a "db.getSiblingDB('${SHARD_DB}').items.countDocuments({})")"; c2="$(mauth s2a "db.getSiblingDB('${SHARD_DB}').items.countDocuments({})")"
  echo "   shard1(s1a)=${c1:-0}  shard2(s2a)=${c2:-0}  (sum should be 200)"
  { [ "${c1:-0}" -gt 0 ] && [ "${c2:-0}" -gt 0 ] && [ "$(( ${c1:-0} + ${c2:-0} ))" = 200 ]; } 2>/dev/null && ok "data distributed across BOTH shards (sharding works)" || { warn "not distributed"; rc=1; }

  echo "== (3) per-shard replication: shard1 secondary (s1b) has the primary's docs =="
  local sec; sec="$(mauth s1b "db.getMongo().setReadPref('secondaryPreferred'); db.getSiblingDB('${SHARD_DB}').items.countDocuments({})" 2>/dev/null | grep -oE '^[0-9]+$' | tail -1)"
  [ "${sec:-0}" = "${c1:-X}" ] && ok "s1b (secondary) replicated shard1's ${c1} docs" || { warn "s1b count=${sec:-0} vs primary ${c1}"; rc=1; }

  echo "== (4) read/write split via mongos: write (primary) + secondary-preference read + UTF-8 =="
  local val; val="$(mauth mongos "db.getSiblingDB('${SHARD_DB}').getMongo().setReadPref('secondaryPreferred'); db.getSiblingDB('${SHARD_DB}').items.findOne({_id:42}).v")"
  [ "$val" = "চাল-42" ] && ok "secondary-preferred read via mongos returns the UTF-8 doc (চাল-42)" || { warn "read got '${val}'"; rc=1; }

  mauth mongos "db.getSiblingDB('${SHARD_DB}').items.deleteMany({})" >/dev/null 2>&1 || true
  [ "$rc" = 0 ] && ok "ACCEPTANCE PASS" || warn "ACCEPTANCE had failures"
  return "$rc"
}

do_down(){ docker compose down; echo "Containers removed. DATA PRESERVED at ${CDIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$CDIR"; echo "Full wipe: containers + ${CDIR} (data + keyFile) removed."; }
do_status(){ docker compose ps || true
  echo "shards: $(mauth mongos "db.getSiblingDB('config').shards.countDocuments({})" 2>/dev/null || echo '?')/2"
  echo "data (host): ${CDIR} ($(sudo du -sh "$CDIR" 2>/dev/null | cut -f1 || echo absent))"; }
do_logs(){ docker compose logs --tail=80 -f; }

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
while [ $# -gt 0 ]; do case "$1" in
  --gen-password) GEN=1; shift;;
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
