#!/usr/bin/env bash
# DOKANDAR utility — Elastic APM stack · Docker Compose single-node (ES + Kibana + apm-server) · wrapper.
# Ported from github.com/jakirhosen9395/elastic-apm. Auto-generates ELASTIC_PASSWORD, KIBANA_PASSWORD
# (kibana_system), KIBANA_ENCRYPTION_KEY (32 chars), APM_SECRET_TOKEN. Staged bring-up: ES → set the
# kibana_system password via the ES API → Kibana + apm-server. apm-server config = ./apm-server.yml.
# Data bind-mounted (survives `down -v`).  Usage:
#   bash setup.sh up [--gen-secrets] | down | purge | status | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${ELASTIC_VERSION:=9.4.2}"
: "${ES_HTTP_PORT:=9200}"; : "${APM_PORT:=8200}"; : "${KIBANA_PORT:=5601}"
DATA_DIR="${DATA_ROOT}/apm_stack"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up [--gen-secrets] | down | purge | status | logs"; }
# SIGPIPE-safe hex generator (od reads a fixed N — no head/SIGPIPE under set -o pipefail). $1 = length.
genhex(){ local s; s="$(od -An -tx1 -N40 /dev/urandom | tr -dc 'a-f0-9')"; printf '%s' "${s:0:${1:-40}}"; }
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true; export "${k}=${v}"
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }

resolve_creds(){
  if [ "$GEN" = 1 ] || [ -z "${ELASTIC_PASSWORD:-}" ];      then ELASTIC_PASSWORD="$(genhex 40)"; fi
  if [ "$GEN" = 1 ] || [ -z "${KIBANA_PASSWORD:-}" ];       then KIBANA_PASSWORD="$(genhex 40)"; fi
  if [ "$GEN" = 1 ] || [ -z "${KIBANA_ENCRYPTION_KEY:-}" ]; then KIBANA_ENCRYPTION_KEY="$(genhex 32)"; fi
  if [ "$GEN" = 1 ] || [ -z "${APM_SECRET_TOKEN:-}" ];      then APM_SECRET_TOKEN="$(genhex 40)"; fi
  set_env_var ELASTIC_PASSWORD "$ELASTIC_PASSWORD"; set_env_var KIBANA_PASSWORD "$KIBANA_PASSWORD"
  set_env_var KIBANA_ENCRYPTION_KEY "$KIBANA_ENCRYPTION_KEY"; set_env_var APM_SECRET_TOKEN "$APM_SECRET_TOKEN"
  set_env_var ELASTIC_VERSION "$ELASTIC_VERSION"; set_env_var ES_HTTP_PORT "$ES_HTTP_PORT"
  set_env_var APM_PORT "$APM_PORT"; set_env_var KIBANA_PORT "$KIBANA_PORT"
}

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (secrets shown ONCE — copy them into your test env)"
  printf '%s' "$(_c '1;36')"; echo "========= Elastic APM ${ELASTIC_VERSION} stack (Docker) — connection details ========="; printf '%s' "$(_c 0)"
  cat <<SUM
  APM ingest     : http://${host}:${APM_PORT}   (agents send here; Authorization: Bearer <secret_token>; RUM on)
  APM secret tok : ${APM_SECRET_TOKEN}
  Elasticsearch  : http://${host}:${ES_HTTP_PORT}   (user elastic / ${ELASTIC_PASSWORD})
  kibana_system  : ${KIBANA_PASSWORD}   (Kibana logs in as this user)
  Kibana (UI)    : http://${host}:${KIBANA_PORT}   (APM app at /app/apm; log in as elastic)
  Test from afar : APM_HOST=${host} APM_PORT=${APM_PORT} ES_HTTP_PORT=${ES_HTTP_PORT} KIBANA_PORT=${KIBANA_PORT} APM_SECRET_TOKEN=${APM_SECRET_TOKEN} ELASTIC_PASSWORD=${ELASTIC_PASSWORD} bash ../test.sh
  Data (host)    : ${DATA_DIR}/es   (bind mount — survives 'down -v')
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "===================================================================================="; printf '%s' "$(_c 0)"
}

wait_health(){ local c="$1"; for _ in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo)" = healthy ] && return 0; sleep 3; done; return 1; }

do_up(){
  resolve_creds
  step "1/5  Configuration"; ok "es=${ES_HTTP_PORT} apm=${APM_PORT} kibana=${KIBANA_PORT}  secrets $([ "$GEN" = 1 ] && echo '(rotated)' || echo 'ready')"
  step "2/5  vm.max_map_count + data dir"; sudo sysctl -w vm.max_map_count=262144 >/dev/null 2>&1 || true
  sudo mkdir -p "$DATA_DIR/es"; sudo chown -R 1000:1000 "$DATA_DIR"; ok "$DATA_DIR/es (uid 1000)"
  step "3/5  Start Elasticsearch + set the kibana_system password (ES API)"
  docker compose up -d elasticsearch
  printf '   waiting for ES healthy'; wait_health dokandar_apm_es && echo ' ✓' || warn "ES not healthy"
  curl -s -u "elastic:${ELASTIC_PASSWORD}" -H 'content-type: application/json' -X POST \
    "http://localhost:${ES_HTTP_PORT}/_security/user/kibana_system/_password" -d "{\"password\":\"${KIBANA_PASSWORD}\"}" >/dev/null 2>&1 \
    && ok "kibana_system password set" || warn "could not set kibana_system password"
  step "4/5  Start apm-server + Kibana"
  docker compose up -d
  printf '   waiting for apm-server :%s' "$APM_PORT"
  for _ in $(seq 1 30); do [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://localhost:${APM_PORT}/" 2>/dev/null)" = 200 ] && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  printf '   waiting for kibana (slow first boot)'; wait_health dokandar_apm_kibana && echo ' ✓' || warn "kibana still starting"
  step "5/5  Verify"
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${APM_PORT}/" 2>/dev/null)" = 200 ] && ok "apm-server ingest reachable on :${APM_PORT}" || warn "apm-server not answering"
  docker compose ps
  print_summary
}

do_down(){ docker compose down; echo "Containers removed. DATA PRESERVED at ${DATA_DIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$DATA_DIR"; echo "Full wipe: containers + ${DATA_DIR} removed."; }
do_status(){ docker compose ps || true
  curl -fsS -o /dev/null --max-time 5 "http://localhost:${APM_PORT}/" 2>/dev/null && echo "apm-server : OK on :${APM_PORT}" || echo "apm-server : DOWN on :${APM_PORT}"
  echo "data (host): ${DATA_DIR} ($(sudo du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"; }
do_logs(){ docker compose logs --tail=80 -f; }

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
GEN=0                                              # parse flags AFTER the subcommand is stripped
while [ $# -gt 0 ]; do case "$1" in --gen-secrets|--gen-password) GEN=1; shift;; *) break;; esac; done
case "$cmd" in
  up|install)     do_up ;;
  down|uninstall) do_down ;;
  purge)          do_purge ;;
  status)         do_status ;;
  logs)           do_logs ;;
  *) usage; exit 2 ;;
esac
