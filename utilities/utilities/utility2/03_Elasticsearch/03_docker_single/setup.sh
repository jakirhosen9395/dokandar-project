#!/usr/bin/env bash
# DOKANDAR utility — Elasticsearch 9.4 · Docker Compose single-node · lifecycle wrapper.
# Security ON (elastic superuser); auto-generates a COMPLEX password when none is set; --gen-password rotates.
# Data is a HOST bind mount (${DATA_ROOT}/elasticsearch_docker) and SURVIVES `docker compose down -v`.
#   Usage:  bash setup.sh up [--password P | --gen-password] | down | purge | status | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || { echo "No .env here — run:  cp .env.example .env"; exit 2; }
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${ES_IMAGE_TAG:=9.4.2}"; : "${ES_HTTP_PORT:=9200}"
DATA_DIR="${DATA_ROOT}/elasticsearch_docker"; CID=dokandar_es_docker_single; SVC=elasticsearch

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up [--password P | --gen-password] | down | purge | status | logs"; }

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
  set_env_var ELASTIC_PASSWORD "$PASS_"; set_env_var ES_HTTP_PORT "$ES_HTTP_PORT"; set_env_var ES_IMAGE_TAG "$ES_IMAGE_TAG"
}

# curl inside the container against the local node. $1=password $2..=curl args
ces(){ local pw="$1"; shift; docker compose exec -T "$SVC" curl -s -u "elastic:$pw" "$@"; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (password shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "============ Elasticsearch ${ES_IMAGE_TAG} (Docker) — connection details ============"; printf '%s' "$(_c 0)"
  cat <<SUM
  REST endpoint  : http://${host}:${ES_HTTP_PORT}   (container 9200)
  Security       : ON — HTTP basic auth (security enabled, http TLS off)
  User           : elastic   (built-in superuser)
  Password       : ${PASS_}   [${PW_SRC}]
  Connection URL : http://elastic:${PASS_}@${host}:${ES_HTTP_PORT}
  curl           : curl -s -u elastic:${PASS_} http://${host}:${ES_HTTP_PORT}/_cluster/health?pretty
  Test from afar : bash ../test.sh "http://elastic:${PASS_}@${host}:${ES_HTTP_PORT}"
  Data (host)    : ${DATA_DIR}   (bind mount — survives 'down -v')
  Browser UI     : none (Kibana is a separate companion)
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "==================================================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  resolve_creds
  step "1/4  Configuration"; ok "user=elastic  host-port=${ES_HTTP_PORT}  image=${ES_IMAGE_TAG}  password=${PW_SRC}"
  step "2/4  vm.max_map_count + bind-mount data dir"
  sudo sysctl -w vm.max_map_count=262144 >/dev/null 2>&1 || true
  sudo mkdir -p "$DATA_DIR"; sudo chown -R 1000:1000 "$DATA_DIR"; ok "$DATA_DIR (uid 1000 = elasticsearch)"
  step "3/4  docker compose up -d"; docker compose up -d
  printf '   waiting for healthy'
  for _ in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Health.Status}}' "$CID" 2>/dev/null || echo)" = healthy ] && { echo ' ✓'; break; }; printf '.'; sleep 3; done
  step "4/4  Verify / rotate the 'elastic' password"
  if [ "$(ces "$PASS_" http://localhost:9200/_cluster/health 2>/dev/null | grep -oE 'green|yellow' | head -1)" ]; then
    ok "elastic authenticates with the current password"
  elif [ -n "$OLD_PASS" ] && ces "$OLD_PASS" http://localhost:9200/_cluster/health 2>/dev/null | grep -qE 'green|yellow'; then
    ces "$OLD_PASS" -X POST http://localhost:9200/_security/user/elastic/_password -H 'Content-Type: application/json' -d "{\"password\":\"${PASS_}\"}" >/dev/null 2>&1 && ok "rotated elastic password" || warn "rotate failed"
  else warn "could not authenticate — see 'bash setup.sh logs'"; fi
  docker compose ps
  print_summary
}

do_down(){ docker compose down; echo "Container removed. DATA PRESERVED at ${DATA_DIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$DATA_DIR"; echo "Full wipe: container + ${DATA_DIR} removed."; }
do_status(){ docker compose ps || true; echo "user: elastic (password in ${ENV_FILE})"; echo "data (host): ${DATA_DIR} ($(sudo du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"; }
do_logs(){ docker compose logs --tail=80 -f; }

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  up|install)     parse_args "$@"; do_up ;;
  down|uninstall) do_down ;;
  purge)          do_purge ;;
  status)         do_status ;;
  logs)           do_logs ;;
  *) usage; exit 2 ;;
esac
