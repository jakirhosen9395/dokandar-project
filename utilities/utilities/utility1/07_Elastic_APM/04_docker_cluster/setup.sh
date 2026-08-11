#!/usr/bin/env bash
# DOKANDAR utility — Elastic APM 9.4 · Docker Compose HA · ES + 2 APM Server replicas + Kibana · wrapper.
# Auto-generates the ES password, kibana_system password, APM secret token. Brings ES up first, sets the
# kibana_system password, then starts Kibana + 2 stateless APM Server replicas (apm-1 :8200, apm-2 :8201).
#   Usage:  bash setup.sh up [--gen-password] | down | purge | status | acceptance | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || { echo "No .env here — run:  cp .env.example .env"; exit 2; }
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${ELASTIC_VERSION:=9.4.2}"
: "${ES_HTTP_PORT:=9200}"; : "${APM_PORT:=8200}"; : "${APM_PORT2:=8201}"; : "${KIBANA_PORT:=5601}"
DATA_DIR="${DATA_ROOT}/apm_stack"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up [--gen-password] | down | purge | status | acceptance | logs"; }
gen_secret(){ printf '%s' "$( set +o pipefail
  { command -v openssl >/dev/null 2>&1 && openssl rand -base64 48 || head -c 256 /dev/urandom; } \
  | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"${1:-24}" )"; }
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true; export "${k}=${v}"
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }

GEN=0; [ "${1:-}" = --gen-password ] && GEN=1
resolve_creds(){
  if [ "$GEN" = 1 ] || [ -z "${ELASTIC_PASSWORD:-}" ]; then ELASTIC_PASSWORD="$(gen_secret)"; fi
  if [ "$GEN" = 1 ] || [ -z "${KIBANA_SYSTEM_PASSWORD:-}" ]; then KIBANA_SYSTEM_PASSWORD="$(gen_secret)"; fi
  [ -n "${APM_SECRET_TOKEN:-}" ] || APM_SECRET_TOKEN="$(gen_secret 32)"
  set_env_var ELASTIC_PASSWORD "$ELASTIC_PASSWORD"; set_env_var KIBANA_SYSTEM_PASSWORD "$KIBANA_SYSTEM_PASSWORD"
  set_env_var APM_SECRET_TOKEN "$APM_SECRET_TOKEN"; set_env_var ELASTIC_VERSION "$ELASTIC_VERSION"
  set_env_var ES_HTTP_PORT "$ES_HTTP_PORT"; set_env_var APM_PORT "$APM_PORT"; set_env_var APM_PORT2 "$APM_PORT2"; set_env_var KIBANA_PORT "$KIBANA_PORT"
}
wait_es(){ for _ in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Health.Status}}' dokandar_apm_es 2>/dev/null || echo)" = healthy ] && return 0; sleep 3; done; return 1; }
wait_http(){ for _ in $(seq 1 30); do [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$1" 2>/dev/null)" = 200 ] && return 0; sleep 2; done; return 1; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (secrets shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "===== Elastic APM ${ELASTIC_VERSION} HA (ES + 2 APM replicas + Kibana) — connection details ====="; printf '%s' "$(_c 0)"
  cat <<SUM
  APM ingest     : http://${host}:${APM_PORT} , http://${host}:${APM_PORT2}   (2 stateless replicas)
  APM secret tok : ${APM_SECRET_TOKEN}
  Elasticsearch  : http://${host}:${ES_HTTP_PORT}   (user elastic / ${ELASTIC_PASSWORD})
  Kibana (UI)    : http://${host}:${KIBANA_PORT}   (APM app at /app/apm)
  Verify HA      : bash setup.sh acceptance
  Test from afar : APM_HOST=${host} APM_SECRET_TOKEN=${APM_SECRET_TOKEN} ELASTIC_PASSWORD=${ELASTIC_PASSWORD} bash ../test.sh
  Data (host)    : ${DATA_DIR}/es   (bind mount — survives 'down -v')
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "==========================================================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  resolve_creds
  step "1/4  Configuration"; ok "es=${ES_HTTP_PORT} apm=${APM_PORT},${APM_PORT2} kibana=${KIBANA_PORT}"
  step "2/4  vm.max_map_count + data dir + start ES + set kibana_system password"
  sudo sysctl -w vm.max_map_count=262144 >/dev/null 2>&1 || true
  sudo mkdir -p "$DATA_DIR/es"; sudo chown -R 1000:1000 "$DATA_DIR"
  docker compose up -d elasticsearch
  printf '   waiting for ES healthy'; wait_es && echo ' ✓' || warn "ES not healthy"
  curl -s -u "elastic:${ELASTIC_PASSWORD}" -H 'content-type: application/json' -X POST \
    "http://localhost:${ES_HTTP_PORT}/_security/user/kibana_system/_password" -d "{\"password\":\"${KIBANA_SYSTEM_PASSWORD}\"}" >/dev/null 2>&1 && ok "kibana_system password set" || warn "kibana_system set failed"
  step "3/4  Start Kibana + 2 APM Server replicas"
  docker compose up -d
  printf '   waiting for apm-1 :%s' "$APM_PORT"; wait_http "http://localhost:${APM_PORT}/" && echo ' ✓' || warn "apm-1 not answering"
  printf '   waiting for apm-2 :%s' "$APM_PORT2"; wait_http "http://localhost:${APM_PORT2}/" && echo ' ✓' || warn "apm-2 not answering"
  printf '   waiting for kibana (slow)'; for _ in $(seq 1 40); do [ "$(docker inspect -f '{{.State.Health.Status}}' dokandar_apm_kibana 2>/dev/null||echo)" = healthy ] && { echo ' ✓'; break; }; sleep 3; done
  step "4/4  Done"; docker compose ps; print_summary
}

do_acceptance(){
  : "${ELASTIC_PASSWORD:?}"; : "${APM_SECRET_TOKEN:?}"
  for pr in "${APM_PORT}:apm-1" "${APM_PORT2}:apm-2"; do
    local p="${pr%%:*}" n="${pr##*:}"; local svc="ha_check_${n}_$$"
    local tid trace tsu; tid="$(head -c8 /dev/urandom|od -An -tx1|tr -d ' \n')"; trace="$(head -c16 /dev/urandom|od -An -tx1|tr -d ' \n')"; tsu="$(date +%s)000000"
    printf '{"metadata":{"service":{"name":"%s","agent":{"name":"go","version":"2.0.0"}}}}\n{"transaction":{"id":"%s","trace_id":"%s","type":"request","name":"acc","duration":1,"timestamp":%s,"span_count":{"started":0}}}\n' "$svc" "$tid" "$trace" "$tsu" \
      | curl -s -o /dev/null -w "   ${n} (:${p}) intake http=%{http_code}\n" -H "Authorization: Bearer ${APM_SECRET_TOKEN}" -H 'Content-Type: application/x-ndjson' --data-binary @- "http://localhost:${p}/intake/v2/events"
    sleep 3
    local c; c="$(curl -s -u "elastic:${ELASTIC_PASSWORD}" -H 'content-type: application/json' "http://localhost:${ES_HTTP_PORT}/traces-apm*/_count?ignore_unavailable=true" -d "{\"query\":{\"term\":{\"service.name\":\"${svc}\"}}}" 2>/dev/null | grep -oE '"count":[0-9]+' | cut -d: -f2)"
    [ "${c:-0}" -ge 1 ] 2>/dev/null && echo "   OK: ${n} event reached ES" || echo "   FAIL: ${n} event not in ES (count=${c:-0})"
    curl -s -u "elastic:${ELASTIC_PASSWORD}" -H 'content-type: application/json' -X POST "http://localhost:${ES_HTTP_PORT}/traces-apm*/_delete_by_query?refresh=true&ignore_unavailable=true" -d "{\"query\":{\"term\":{\"service.name\":\"${svc}\"}}}" >/dev/null 2>&1 || true
  done
}

do_down(){ docker compose down; echo "Containers removed. DATA PRESERVED at ${DATA_DIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$DATA_DIR"; echo "Full wipe: containers + ${DATA_DIR} removed."; }
do_status(){ docker compose ps || true; echo "data: ${DATA_DIR} ($(sudo du -sh "$DATA_DIR" 2>/dev/null|cut -f1||echo absent))"; }
do_logs(){ docker compose logs --tail=80 -f; }

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  up|install) do_up ;; down|uninstall) do_down ;; purge) do_purge ;; status) do_status ;; acceptance) do_acceptance ;; logs) do_logs ;;
  *) usage; exit 2 ;;
esac
