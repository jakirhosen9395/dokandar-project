#!/usr/bin/env bash
# DOKANDAR utility — RabbitMQ 4.x · Docker Compose HA cluster (3 nodes, quorum queues) · lifecycle wrapper.
# rabbit-1/2/3 share an Erlang cookie; setup.sh joins nodes 2+3 to node 1. Auth ON (admin user). Clients
# use node 1's published AMQP/Management ports. Per-node data are HOST bind mounts (survive down -v).
#   Usage:  bash setup.sh up [--password P | --gen-password] | down | purge | status | acceptance | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || { echo "No .env here — run:  cp .env.example .env"; exit 2; }
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${RABBITMQ_IMAGE_TAG:=4-management}"; : "${RABBITMQ_AMQP_PORT:=5672}"; : "${RABBITMQ_MGMT_PORT:=15672}"
DATA_DIR="${DATA_ROOT}/rabbitmq_cluster"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up [--password P | --gen-password] | down | purge | status | acceptance | logs"; }
gen_secret(){ printf '%s' "$( set +o pipefail
  { command -v openssl >/dev/null 2>&1 && openssl rand -base64 48 || head -c 256 /dev/urandom; } \
  | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"${1:-24}" )"; }
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
  USER_="${RABBITMQ_DEFAULT_USER:-dokandar}"
  [ -n "${RABBITMQ_ERLANG_COOKIE:-}" ] || RABBITMQ_ERLANG_COOKIE="$(gen_secret 20)"
  if   [ -n "$PASS_ARG" ];                  then PASS_="$PASS_ARG";              PW_SRC="provided (--password)"
  elif [ "$GEN" = 1 ];                      then PASS_="$(gen_secret)";          PW_SRC="auto-generated (--gen-password)"
  elif [ -n "${RABBITMQ_DEFAULT_PASS:-}" ]; then PASS_="$RABBITMQ_DEFAULT_PASS"; PW_SRC="reused from .env"
  else                                           PASS_="$(gen_secret)";          PW_SRC="auto-generated (.env was empty)"
  fi
  set_env_var RABBITMQ_DEFAULT_USER "$USER_"; set_env_var RABBITMQ_DEFAULT_PASS "$PASS_"
  set_env_var RABBITMQ_ERLANG_COOKIE "$RABBITMQ_ERLANG_COOKIE"
  set_env_var RABBITMQ_AMQP_PORT "$RABBITMQ_AMQP_PORT"; set_env_var RABBITMQ_MGMT_PORT "$RABBITMQ_MGMT_PORT"; set_env_var RABBITMQ_IMAGE_TAG "$RABBITMQ_IMAGE_TAG"
}

rc1(){ docker compose exec -T rabbit-1 rabbitmqctl "$@" 2>/dev/null; }
healthy_count(){ local n=0; for c in dokandar_rabbit_1 dokandar_rabbit_2 dokandar_rabbit_3; do [ "$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo)" = healthy ] && n=$((n+1)); done; echo "$n"; }
join_node(){ local svc="$1"
  docker compose exec -T "$svc" rabbitmqctl cluster_status 2>/dev/null | grep -q 'rabbit@rabbit-1' && return 0
  docker compose exec -T "$svc" rabbitmqctl stop_app  >/dev/null 2>&1 || true
  docker compose exec -T "$svc" rabbitmqctl reset     >/dev/null 2>&1 || true
  docker compose exec -T "$svc" rabbitmqctl join_cluster rabbit@rabbit-1 >/dev/null 2>&1 || true
  docker compose exec -T "$svc" rabbitmqctl start_app >/dev/null 2>&1 || true
}

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (password shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "========= RabbitMQ ${RABBITMQ_IMAGE_TAG} HA cluster (Docker) — connection details ========="; printf '%s' "$(_c 0)"
  cat <<SUM
  AMQP endpoint  : ${host}:${RABBITMQ_AMQP_PORT}   (node 1; cluster is transparent)
  User           : ${USER_}   (administrator)
  Password       : ${PASS_}   [${PW_SRC}]
  AMQP URL       : amqp://${USER_}:${PASS_}@${host}:${RABBITMQ_AMQP_PORT}/
  Browser UI     : http://${host}:${RABBITMQ_MGMT_PORT}   (Management plugin)
  Test (cluster) : bash ../test.sh "http://${USER_}:${PASS_}@${host}:${RABBITMQ_MGMT_PORT}"
  Verify HA      : bash setup.sh acceptance
  Nodes          : rabbit@rabbit-1, rabbit@rabbit-2, rabbit@rabbit-3 (shared Erlang cookie)
  Data (host)    : ${DATA_DIR}/{n1,n2,n3}   (bind mounts — survive 'down -v')
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "==========================================================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  resolve_creds
  step "1/4  Configuration"; ok "3 nodes  user=${USER_}  amqp=${RABBITMQ_AMQP_PORT}  mgmt=${RABBITMQ_MGMT_PORT}  password=${PW_SRC}"
  step "2/4  Per-node data dirs + docker compose up (3 nodes)"
  for n in 1 2 3; do sudo mkdir -p "$DATA_DIR/n$n"; done; sudo chown -R 999:999 "$DATA_DIR"   # uid 999 = rabbitmq
  docker compose up -d
  printf '   waiting for 3 healthy nodes'
  for _ in $(seq 1 60); do [ "$(healthy_count)" = 3 ] && { echo ' ✓'; break; }; printf '.'; sleep 3; done
  step "3/4  Join nodes 2 + 3 to rabbit@rabbit-1 (idempotent)"
  join_node rabbit-2; join_node rabbit-3
  rc1 set_user_tags "$USER_" administrator >/dev/null 2>&1 || true
  rc1 set_permissions -p / "$USER_" ".*" ".*" ".*" >/dev/null 2>&1 || true
  local running; running="$(rc1 cluster_status 2>/dev/null | grep -oE 'rabbit@rabbit-[123]' | sort -u | wc -l | tr -d ' ')"
  ok "cluster members: ${running:-?}/3"
  step "4/4  Cluster status"
  rc1 cluster_status 2>/dev/null | grep -iE 'running nodes|rabbit@rabbit-[123]' | head -4 | sed 's/^/   /' || true
  docker compose ps
  print_summary
}

do_acceptance(){
  : "${RABBITMQ_DEFAULT_PASS:?}"; local U="${RABBITMQ_DEFAULT_USER:-dokandar}" P="$RABBITMQ_DEFAULT_PASS" Q="ha_check_$$"
  echo "== (1) running nodes == 3 =="
  echo "   $(docker compose exec -T rabbit-1 rabbitmqctl list_queues >/dev/null 2>&1; docker compose exec -T rabbit-1 rabbitmqctl cluster_status 2>/dev/null | grep -oE 'rabbit@rabbit-[123]' | sort -u | tr '\n' ' ')"
  echo "== (2) quorum queue replicated to 3 members =="
  docker compose exec -T rabbit-1 rabbitmqctl -q add_vhost / >/dev/null 2>&1 || true
  curl -s -u "${U}:${P}" -H 'content-type: application/json' -X PUT "http://localhost:${RABBITMQ_MGMT_PORT}/api/queues/%2F/${Q}" -d '{"durable":true,"arguments":{"x-queue-type":"quorum"}}' >/dev/null 2>&1
  sleep 2
  local m; m="$(curl -s -u "${U}:${P}" "http://localhost:${RABBITMQ_MGMT_PORT}/api/queues/%2F/${Q}" 2>/dev/null | grep -oE 'rabbit@rabbit-[123]' | sort -u | wc -l | tr -d ' ')"
  echo "   quorum members: ${m}"; [ "$m" = 3 ] && echo "OK: replicated to 3 nodes" || echo "FAIL: not 3 members"
  curl -s -u "${U}:${P}" -X DELETE "http://localhost:${RABBITMQ_MGMT_PORT}/api/queues/%2F/${Q}" >/dev/null 2>&1 || true
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
