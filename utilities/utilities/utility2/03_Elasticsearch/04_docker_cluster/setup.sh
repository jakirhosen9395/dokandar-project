#!/usr/bin/env bash
# DOKANDAR utility — Elasticsearch 9.4 · Docker Compose HA cluster (3 nodes) · lifecycle wrapper.
# Security ON; auto-generates the elastic password + a shared transport-TLS cert (PKCS12). HTTP basic
# auth over plain HTTP. Per-node data are HOST bind mounts (survive `docker compose down -v`).
#   Usage:  bash setup.sh up [--password P | --gen-password] | down | purge | status | acceptance | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || { echo "No .env here — run:  cp .env.example .env"; exit 2; }
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${ES_IMAGE_TAG:=9.4.2}"; : "${ES_CLUSTER_NAME:=dokandar}"
: "${ES_PORT1:=9200}"; : "${ES_PORT2:=9201}"; : "${ES_PORT3:=9202}"
DATA_DIR="${DATA_ROOT}/es_cluster"; : "${CERTS_HOST_PATH:=${DATA_DIR}/certs}"
IMG="docker.elastic.co/elasticsearch/elasticsearch:${ES_IMAGE_TAG}"

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

OLD_PASS=""
resolve_creds(){
  OLD_PASS="${ELASTIC_PASSWORD:-}"
  if   [ -n "$PASS_ARG" ];               then PASS_="$PASS_ARG";            PW_SRC="provided (--password)"
  elif [ "$GEN" = 1 ];                   then PASS_="$(gen_password)";      PW_SRC="auto-generated (--gen-password)"
  elif [ -n "${ELASTIC_PASSWORD:-}" ];   then PASS_="$ELASTIC_PASSWORD";    PW_SRC="reused from .env"
  else                                        PASS_="$(gen_password)";      PW_SRC="auto-generated (.env was empty)"
  fi
  set_env_var ELASTIC_PASSWORD "$PASS_"; set_env_var ES_IMAGE_TAG "$ES_IMAGE_TAG"
  set_env_var ES_PORT1 "$ES_PORT1"; set_env_var ES_PORT2 "$ES_PORT2"; set_env_var ES_PORT3 "$ES_PORT3"
  set_env_var CERTS_HOST_PATH "$CERTS_HOST_PATH"
}

ensure_certs(){
  sudo mkdir -p "$CERTS_HOST_PATH"
  if [ ! -f "$CERTS_HOST_PATH/node.p12" ]; then
    # generate a CA + a node keystore (PKCS12, empty password) shared by all 3 nodes; DNS SANs cover es0X.
    sudo docker run --rm --user 0 -v "${CERTS_HOST_PATH}:/certs" "$IMG" bash -c '
      set -e; cd /usr/share/elasticsearch
      bin/elasticsearch-certutil ca --silent --out /certs/ca.p12 --pass ""
      bin/elasticsearch-certutil cert --silent --ca /certs/ca.p12 --ca-pass "" \
        --dns es01,es02,es03 --name node --out /certs/node.p12 --pass ""
      chown -R 1000:1000 /certs; chmod 644 /certs/*.p12' >/dev/null 2>&1
  fi
  sudo chown -R 1000:1000 "$CERTS_HOST_PATH" 2>/dev/null || true
}

# curl inside es01 against the local node. $1=password $2..=curl args
ces(){ local pw="$1"; shift; docker compose exec -T es01 curl -s -u "elastic:$pw" "$@"; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (password shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "========= Elasticsearch ${ES_IMAGE_TAG} HA cluster (Docker) — connection details ========="; printf '%s' "$(_c 0)"
  cat <<SUM
  Nodes (any RW) : ${host}:${ES_PORT1} , ${host}:${ES_PORT2} , ${host}:${ES_PORT3}   (es01/es02/es03)
  Cluster name   : ${ES_CLUSTER_NAME}   (3 nodes, transport TLS on, http basic auth)
  User           : elastic   (built-in superuser)
  Password       : ${PASS_}   [${PW_SRC}]
  Transport cert : ${CERTS_HOST_PATH}/node.p12   (shared PKCS12, internal-auth secret)
  Connection URL : http://elastic:${PASS_}@${host}:${ES_PORT1}
  curl           : curl -s -u elastic:${PASS_} http://${host}:${ES_PORT1}/_cluster/health?pretty
  Test (any node): bash ../test.sh "http://elastic:${PASS_}@${host}:${ES_PORT1}"
  Verify HA      : bash setup.sh acceptance
  Data (host)    : ${DATA_DIR}/{es01,es02,es03}   (bind mounts — survive 'down -v')
  Browser UI     : none (Kibana is a separate companion)
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "============================================================================================"; printf '%s' "$(_c 0)"
}

wait_healthy(){
  printf '   waiting for 3 healthy nodes'
  for _ in $(seq 1 80); do
    local n; n=$(for c in dokandar_es01 dokandar_es02 dokandar_es03; do
      [ "$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo)" = healthy ] && echo x; done | wc -l)
    [ "$n" = 3 ] && { echo ' ✓'; return 0; }; printf '.'; sleep 3
  done; echo ' (timeout)'; return 1
}

do_up(){
  resolve_creds
  step "1/5  Configuration"; ok "ports=${ES_PORT1}/${ES_PORT2}/${ES_PORT3}  cluster=${ES_CLUSTER_NAME}  password=${PW_SRC}"
  step "2/5  vm.max_map_count + transport cert (PKCS12) + per-node data dirs"
  sudo sysctl -w vm.max_map_count=262144 >/dev/null 2>&1 || true
  ensure_certs; ok "transport cert ${CERTS_HOST_PATH}/node.p12"
  for n in es01 es02 es03; do sudo mkdir -p "$DATA_DIR/$n"; done
  sudo chown -R 1000:1000 "$DATA_DIR"; ok "$DATA_DIR/{es01,es02,es03}"
  step "3/5  docker compose up (3 nodes)"; docker compose up -d; wait_healthy || warn "not all healthy — see logs"
  step "4/5  Verify / rotate the 'elastic' password"
  if ces "$PASS_" http://localhost:9200/_cluster/health 2>/dev/null | grep -qE 'green|yellow'; then
    ok "elastic authenticates with the current password"
  elif [ -n "$OLD_PASS" ] && ces "$OLD_PASS" http://localhost:9200/_cluster/health 2>/dev/null | grep -qE 'green|yellow'; then
    ces "$OLD_PASS" -X POST http://localhost:9200/_security/user/elastic/_password -H 'Content-Type: application/json' -d "{\"password\":\"${PASS_}\"}" >/dev/null 2>&1 && ok "rotated elastic password" || warn "rotate failed"
  else warn "could not authenticate — see 'bash setup.sh logs'"; fi
  step "5/5  Cluster state"
  ces "$PASS_" "http://localhost:9200/_cat/nodes?h=name,node.role,master" 2>/dev/null | sed 's/^/   /' || true
  docker compose ps
  print_summary
}

do_acceptance(){
  : "${ELASTIC_PASSWORD:?}"
  # curl with a Docker fallback (no host packages needed for the read/write-split acceptance).
  if command -v curl >/dev/null 2>&1; then CURL(){ curl "$@"; }
  else docker image inspect curlimages/curl:latest >/dev/null 2>&1 || docker pull -q curlimages/curl:latest >/dev/null 2>&1 || true; CURL(){ docker run --rm -i --network host curlimages/curl:latest "$@"; }; fi
  local A="-u elastic:${ELASTIC_PASSWORD}" N1="http://localhost:${ES_PORT1}" N2="http://localhost:${ES_PORT2}" N3="http://localhost:${ES_PORT3}"
  echo "== (1) cluster health: 3 nodes, status green/yellow =="
  CURL -s $A "$N1/_cluster/health?filter_path=status,number_of_nodes"
  echo ""
  echo "== (2) write on es01, read it back from es03 (replicated) =="
  CURL -s $A -X PUT "$N1/ha_check?wait_for_active_shards=all" -H 'Content-Type: application/json' -d '{"settings":{"number_of_replicas":2}}' >/dev/null
  CURL -s $A -X POST "$N1/ha_check/_doc/1?refresh=wait_for" -H 'Content-Type: application/json' -d '{"note":"replicated"}' >/dev/null
  local C; C="$(CURL -s $A "$N3/ha_check/_doc/1?filter_path=_source.note" | grep -o replicated)"
  [ "$C" = replicated ] && echo "OK: es03 sees the doc written on es01" || echo "FAIL: replication"
  echo "== (3) node count == 3 =="
  CURL -s $A "$N2/_cat/nodes?h=name" | sort | tr '\n' ' '; echo ""
  CURL -s $A -X DELETE "$N1/ha_check" >/dev/null 2>&1 || true
}

do_down(){ docker compose down; echo "Containers removed. DATA + certs PRESERVED under ${DATA_DIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$DATA_DIR"; echo "Full wipe: containers + ${DATA_DIR} (data + certs) removed."; }
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
