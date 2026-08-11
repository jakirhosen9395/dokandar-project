#!/usr/bin/env bash
# DOKANDAR utility — Redis 8 · Docker Compose HA cluster (Redis Cluster) · lifecycle wrapper.
# 6 nodes (3 primaries + 3 replicas), ports 7001-7006, auth (requirepass + masterauth). Host networking
# + cluster-announce-ip so the cluster is reachable locally AND cross-host. Per-node data are HOST bind
# mounts (survive `docker compose down -v`).
#   Usage:  bash setup.sh up [--password P | --gen-password] | down | purge | status | acceptance | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || { echo "No .env here — run:  cp .env.example .env"; exit 2; }
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${REDIS_VERSION:=8}"
DATA_DIR="${DATA_ROOT}/redis_cluster"; PORTS="7001 7002 7003 7004 7005 7006"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up [--password P | --gen-password] | down | purge | status | acceptance | logs"; }

gen_password(){ printf '%s' "$( set +o pipefail
  { command -v openssl >/dev/null 2>&1 && openssl rand -base64 48 || head -c 256 /dev/urandom; } \
  | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24 )"; }
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true; export "${k}=${v}"
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }

PASS_ARG=""; GEN=0
parse_args(){ while [ $# -gt 0 ]; do case "$1" in
    --password) PASS_ARG="${2:?}"; shift 2;; --password=*) PASS_ARG="${1#*=}"; shift;;
    --gen-password) GEN=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1"; usage; exit 2;;
  esac; done; }

resolve_creds(){
  ANNOUNCE_IP="${CLUSTER_ANNOUNCE_IP:-${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}}"
  [ -n "$ANNOUNCE_IP" ] || ANNOUNCE_IP=127.0.0.1
  if   [ -n "$PASS_ARG" ];               then PASS_="$PASS_ARG";            PW_SRC="provided (--password)"
  elif [ "$GEN" = 1 ];                   then PASS_="$(gen_password)";      PW_SRC="auto-generated (--gen-password)"
  elif [ -n "${REDIS_PASSWORD:-}" ];     then PASS_="$REDIS_PASSWORD";      PW_SRC="reused from .env"
  else                                        PASS_="$(gen_password)";      PW_SRC="auto-generated (.env was empty)"
  fi
  set_env_var REDIS_PASSWORD "$PASS_"; set_env_var CLUSTER_ANNOUNCE_IP "$ANNOUNCE_IP"; set_env_var REDIS_VERSION "$REDIS_VERSION"
}

# redis-cli inside node 1 (host network), authenticated. $@ = redis-cli args
rc(){ docker compose exec -T redis-1 redis-cli -a "$PASS_" --no-auth-warning "$@" 2>/dev/null; }

print_summary(){
  step "Connection details (password shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "========= Redis ${REDIS_VERSION} Cluster (Docker) — connection details ========="; printf '%s' "$(_c 0)"
  cat <<SUM
  Topology       : 6 nodes = 3 primaries + 3 replicas   (16384 slots auto-sharded)
  Nodes          : ${ANNOUNCE_IP}:7001 .. ${ANNOUNCE_IP}:7006   (announce-ip = ${ANNOUNCE_IP})
  Auth           : requirepass + masterauth (ACL 'default' user)
  Password       : ${PASS_}   [${PW_SRC}]
  redis-cli (-c) : redis-cli -c -h ${ANNOUNCE_IP} -p 7001 -a '${PASS_}' cluster info
  Test (cluster) : bash ../test.sh "redis://default:${PASS_}@${ANNOUNCE_IP}:7001"
  Verify HA      : bash setup.sh acceptance
  Data (host)    : ${DATA_DIR}/{n1..n6}   (bind mounts — survive 'down -v')
  Browser UI     : none
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "================================================================================"; printf '%s' "$(_c 0)"
}

do_up(){
  resolve_creds
  step "1/4  Configuration"; ok "6 nodes ports=7001-7006  announce-ip=${ANNOUNCE_IP}  auth=on  password=${PW_SRC}"
  step "2/4  Per-node data dirs + docker compose up (6 nodes, host network)"
  for n in 1 2 3 4 5 6; do sudo mkdir -p "$DATA_DIR/n$n"; done; sudo chown -R 999:999 "$DATA_DIR"   # uid 999 = redis
  docker compose up -d
  printf '   waiting for 6 nodes to answer'
  for _ in $(seq 1 30); do
    local n=0; for p in $PORTS; do [ "$(docker compose exec -T redis-1 redis-cli -h "$ANNOUNCE_IP" -p "$p" -a "$PASS_" --no-auth-warning ping 2>/dev/null)" = PONG ] && n=$((n+1)); done
    [ "$n" = 6 ] && { echo ' ✓'; break; }; printf '.'; sleep 2
  done
  step "3/4  Form the cluster (3 primaries + 3 replicas) — idempotent"
  if [ "$(rc -p 7001 cluster info 2>/dev/null | tr -d '\r' | awk -F: '/cluster_state:/{print $2}')" = ok ]; then
    ok "cluster already formed (cluster_state:ok)"
  else
    local NODES=""; for p in $PORTS; do NODES="$NODES ${ANNOUNCE_IP}:$p"; done
    docker compose exec -T redis-1 redis-cli -a "$PASS_" --no-auth-warning --cluster create $NODES --cluster-replicas 1 --cluster-yes 2>&1 | grep -iE "OK|slots|join|error" | tail -4 || true
  fi
  step "4/4  Cluster state"
  printf '   converging'; for _ in $(seq 1 25); do [ "$(rc -p 7001 cluster info 2>/dev/null | tr -d '\r' | awk -F: '/cluster_state:/{print $2}')" = ok ] && { echo ' ✓'; break; }; printf '.'; sleep 1; done
  rc -p 7001 cluster info 2>/dev/null | tr -d '\r' | grep -E 'cluster_state|cluster_known_nodes|cluster_size' | sed 's/^/   /'
  print_summary
}

do_acceptance(){
  : "${REDIS_PASSWORD:?}"; : "${CLUSTER_ANNOUNCE_IP:?}"
  local A="-a ${REDIS_PASSWORD} --no-auth-warning" IP="$CLUSTER_ANNOUNCE_IP"
  echo "== (1) cluster_state ok, 6 nodes, 3 primaries =="
  docker compose exec -T redis-1 redis-cli $A -p 7001 cluster info 2>/dev/null | tr -d '\r' | grep -E 'cluster_state|cluster_known_nodes|cluster_size'
  echo "== (2) primaries / replicas =="
  docker compose exec -T redis-1 redis-cli $A -p 7001 cluster nodes 2>/dev/null | tr -d '\r' | awk '{print "   "$2" "$3}' | sed 's/myself,//'
  echo "== (3) write a key (routed by slot), read it back via -c =="
  docker compose exec -T redis-1 redis-cli -c $A -h "$IP" -p 7001 set ha_check_key "ok" >/dev/null 2>&1
  local v; v="$(docker compose exec -T redis-1 redis-cli -c $A -h "$IP" -p 7002 get ha_check_key 2>/dev/null | tr -d '\r')"
  [ "$v" = ok ] && echo "OK: key read back through a different node (slot redirect works)" || echo "FAIL: cluster routing"
  docker compose exec -T redis-1 redis-cli -c $A -h "$IP" -p 7001 del ha_check_key >/dev/null 2>&1 || true
}

do_down(){ docker compose down; echo "Containers removed. DATA PRESERVED at ${DATA_DIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$DATA_DIR"; echo "Full wipe: containers + ${DATA_DIR} removed."; }
do_status(){ docker compose ps || true; echo "data: ${DATA_DIR} ($(sudo du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"; }
do_logs(){ docker compose logs --tail=80 -f; }

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  up|install)     parse_args "$@"; do_up ;;
  down|uninstall) do_down ;;
  purge)          do_purge ;;
  status)         do_status ;;
  acceptance)     do_acceptance ;;
  logs)           do_logs ;;
  *) usage; exit 2 ;;
esac
