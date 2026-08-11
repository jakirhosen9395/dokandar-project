#!/usr/bin/env bash
# DOKANDAR utility — Elasticsearch 9.4 · native single-node (NO Docker), env-file driven.
# Security is ON (the built-in `elastic` superuser); auto-generates a COMPLEX password when none is set.
# HTTP basic auth over plain HTTP (no cert hassle); single-node so transport TLS is off too.
# Data under ${DATA_ROOT}/elasticsearch (preserved on uninstall; `purge` wipes). Prints creds at the end.
#   Usage:  sudo bash setup.sh install [--password P | --gen-password]
#           sudo bash setup.sh uninstall | purge | status
#   (ES has a fixed superuser `elastic` and creates indices on demand, so --user/--db do not apply.)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
set -a; [ -f /etc/dokandar/.env ] && . /etc/dokandar/.env; [ -f "$ENV_FILE" ] && . "$ENV_FILE"; set +a
: "${DATA_ROOT:=/data}"; : "${ES_VERSION:=9.4}"
: "${ES_HTTP_PORT:=9200}"; : "${ES_NETWORK_HOST:=0.0.0.0}"; : "${ES_CLUSTER_NAME:=dokandar}"; : "${ES_JAVA_HEAP:=512m}"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: sudo bash setup.sh install [--password P | --gen-password] | uninstall | purge | status"; }

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
    --user|--user=*|--db|--db=*) warn "Elasticsearch: --user/--db ignored (fixed superuser 'elastic'; indices on demand)"; [ "$1" = --user ] || [ "$1" = --db ] && shift 2 || shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1"; usage; exit 2;;
  esac; done; }

resolve_creds(){
  if   [ -n "$PASS_ARG" ];               then PASS_="$PASS_ARG";            PW_SRC="provided (--password)"
  elif [ "$GEN" = 1 ];                   then PASS_="$(gen_password)";      PW_SRC="auto-generated (--gen-password)"
  elif [ -n "${ELASTIC_PASSWORD:-}" ];   then PASS_="$ELASTIC_PASSWORD";    PW_SRC="reused from .env"
  else                                        PASS_="$(gen_password)";      PW_SRC="auto-generated (.env was empty)"
  fi
  set_env_var ELASTIC_PASSWORD "$PASS_"; set_env_var ES_HTTP_PORT "$ES_HTTP_PORT"
  set_env_var ES_NETWORK_HOST "$ES_NETWORK_HOST"; set_env_var ES_VERSION "$ES_VERSION"
}

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (password shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "============== Elasticsearch ${ES_VERSION} (native) — connection details =============="; printf '%s' "$(_c 0)"
  cat <<SUM
  REST endpoint  : http://${host}:${ES_HTTP_PORT}   (binds ${ES_NETWORK_HOST}; transport 9300 internal)
  Cluster name   : ${ES_CLUSTER_NAME}   (discovery.type=single-node)
  Security       : ON — HTTP basic auth (xpack.security.enabled=true, http TLS off)
  User           : elastic   (built-in superuser)
  Password       : ${PASS_}   [${PW_SRC}]
  Connection URL : http://elastic:${PASS_}@${host}:${ES_HTTP_PORT}
  curl           : curl -s -u elastic:${PASS_} http://${host}:${ES_HTTP_PORT}/_cluster/health?pretty
  Test from afar : bash ../test.sh "http://elastic:${PASS_}@${host}:${ES_HTTP_PORT}"
  Data directory : ${DATA_ROOT}/elasticsearch
  Browser UI     : none here (Kibana is the companion UI — separate deploy)
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "======================================================================================="; printf '%s' "$(_c 0)"
}

do_install(){
  resolve_creds
  step "1/6  Configuration"
  ok "cluster=${ES_CLUSTER_NAME} bind=${ES_NETWORK_HOST} http=${ES_HTTP_PORT} heap=${ES_JAVA_HEAP} security=on password=${PW_SRC}"

  step "2/6  vm.max_map_count + data dir (/var/lib/elasticsearch -> ${DATA_ROOT}/elasticsearch)"
  sysctl -w vm.max_map_count=262144 >/dev/null 2>&1 || true
  echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-dokandar-elasticsearch.conf
  mkdir -p "$DATA_ROOT/elasticsearch"
  if [ ! -L /var/lib/elasticsearch ]; then
    systemctl stop elasticsearch 2>/dev/null || true
    [ -d /var/lib/elasticsearch ] && cp -a /var/lib/elasticsearch/. "$DATA_ROOT/elasticsearch/" 2>/dev/null || true
    rm -rf /var/lib/elasticsearch; ln -sfn "$DATA_ROOT/elasticsearch" /var/lib/elasticsearch
  fi
  ok "vm.max_map_count=$(sysctl -n vm.max_map_count 2>/dev/null); data root ready (existing data preserved)"

  step "3/6  Installing Elasticsearch ${ES_VERSION} (Elastic 9.x apt repo)"
  if ! dpkg-query -W elasticsearch >/dev/null 2>&1; then
    apt-get update -y >/dev/null
    apt-get install -y wget gnupg curl ca-certificates apt-transport-https >/dev/null
    install -d -m 0755 /etc/apt/keyrings
    wget -qO- https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --batch --yes --dearmor -o /etc/apt/keyrings/elastic.gpg
    echo "deb [signed-by=/etc/apt/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/9.x/apt stable main" > /etc/apt/sources.list.d/elastic-9.x.list
    apt-get update -y >/dev/null
    apt-get install -y "elasticsearch=${ES_VERSION}.*" >/dev/null 2>&1 || apt-get install -y elasticsearch >/dev/null
  fi
  ok "package: $(dpkg-query -W -f='${Version}' elasticsearch 2>/dev/null)"

  step "4/6  Config (heap, single-node, security ON / http TLS off) + chown data"
  chown -R elasticsearch:elasticsearch "$DATA_ROOT/elasticsearch" 2>/dev/null || true
  mkdir -p /etc/elasticsearch/jvm.options.d
  printf -- '-Xms%s\n-Xmx%s\n' "$ES_JAVA_HEAP" "$ES_JAVA_HEAP" > /etc/elasticsearch/jvm.options.d/heap.options
  # remove the deb's auto-generated security block (it defines NESTED xpack.security.*.ssl maps + cert
  # refs + enrollment that conflict with our flat keys and require TLS) — we manage security ourselves.
  sed -i '/BEGIN SECURITY AUTO CONFIGURATION/,/END SECURITY AUTO CONFIGURATION/d' /etc/elasticsearch/elasticsearch.yml 2>/dev/null || true
  sed -i '/^# >>> dokandar managed >>>/,/^# <<< dokandar managed <<</d' /etc/elasticsearch/elasticsearch.yml 2>/dev/null || true
  # drop any remaining flat keys we manage (incl. leftover nested-map headers like `xpack.security.http.ssl:`)
  sed -i -E '/^[[:space:]]*(cluster\.name|network\.host|http\.port|discovery\.type|xpack\.security)([.a-z]*)?[[:space:]]*:/d' /etc/elasticsearch/elasticsearch.yml 2>/dev/null || true
  {
    printf '# >>> dokandar managed >>>\n'
    printf 'cluster.name: %s\n' "$ES_CLUSTER_NAME"
    printf 'network.host: %s\n' "$ES_NETWORK_HOST"
    printf 'http.port: %s\n' "$ES_HTTP_PORT"
    printf 'discovery.type: single-node\n'
    printf 'xpack.security.enabled: true\n'
    printf 'xpack.security.http.ssl.enabled: false\n'
    printf 'xpack.security.transport.ssl.enabled: false\n'
    printf '# <<< dokandar managed <<<\n'
  } >> /etc/elasticsearch/elasticsearch.yml
  ok "elasticsearch.yml managed block written (heap=${ES_JAVA_HEAP})"

  step "5/6  Start + set the 'elastic' password"
  systemctl daemon-reload; systemctl enable --now elasticsearch >/dev/null 2>&1 || true
  local URL="http://localhost:${ES_HTTP_PORT}"
  printf '   waiting for the node'
  for _ in $(seq 1 40); do curl -s --max-time 3 "$URL" >/dev/null 2>&1 && { echo ' ✓'; break; }; printf '.'; sleep 3; done
  # bootstrap: reset to an auto password, then set ours via the REST API
  local BOOT=""
  for _ in $(seq 1 20); do BOOT="$(/usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -a -b -s 2>/dev/null | tr -d '[:space:]')"; [ -n "$BOOT" ] && break; sleep 3; done
  if [ -n "$BOOT" ]; then
    curl -s --max-time 10 -u "elastic:$BOOT" -X POST "$URL/_security/user/elastic/_password" -H 'Content-Type: application/json' -d "{\"password\":\"${PASS_}\"}" >/dev/null 2>&1 || true
  fi
  ok "elastic password set"

  step "6/6  Verify"
  local NUM; NUM="$(curl -s --max-time 5 -u "elastic:${PASS_}" "$URL" | grep -o '"number" : "[^"]*"' | head -1)"
  [ -n "$NUM" ] && ok "auth OK on ${URL} (svc=$(systemctl is-active elasticsearch); ${NUM})" || warn "not answering with auth yet (warming up? journalctl -u elasticsearch)"
  print_summary
}

do_uninstall(){
  step "Stopping Elasticsearch — DATA PRESERVED at ${DATA_ROOT}/elasticsearch"
  systemctl stop elasticsearch >/dev/null 2>&1 || true
  [ -L /var/lib/elasticsearch ] && rm -f /var/lib/elasticsearch
  apt-get purge -y elasticsearch >/dev/null 2>&1 || true
  apt-get autoremove --purge -y >/dev/null 2>&1 || true
  rm -rf /etc/elasticsearch /var/log/elasticsearch
  rm -f /etc/apt/sources.list.d/elastic-9.x.list /etc/apt/keyrings/elastic.gpg /etc/sysctl.d/99-dokandar-elasticsearch.conf
  apt-get update -y >/dev/null 2>&1 || true
  ok "Elasticsearch removed. DATA PRESERVED at ${DATA_ROOT}/elasticsearch ($(du -sh "${DATA_ROOT}/elasticsearch" 2>/dev/null | cut -f1 || echo '?'))."
  warn "To remove the data too: sudo bash setup.sh purge"
}
do_purge(){ do_uninstall; step "Purging data dir ${DATA_ROOT}/elasticsearch"; rm -rf "${DATA_ROOT}/elasticsearch" || true; ok "data dir removed — full wipe."; }

do_status(){
  : "${ES_HTTP_PORT:=9200}"; : "${ELASTIC_PASSWORD:=}"
  printf 'elasticsearch : %s\n' "$(systemctl is-active elasticsearch 2>/dev/null)"
  local H; H="$(curl -s --max-time 5 -u "elastic:${ELASTIC_PASSWORD}" "http://localhost:${ES_HTTP_PORT}/_cluster/health" 2>/dev/null | grep -o '"status":"[^"]*"' | head -1)"
  [ -n "$H" ] && echo "cluster      : ${H} on :${ES_HTTP_PORT}" || echo "cluster      : DOWN/unauthorized on :${ES_HTTP_PORT}"
  echo "user         : elastic   (password in ${ENV_FILE})"
  echo "data dir     : ${DATA_ROOT}/elasticsearch ($(du -sh "${DATA_ROOT}/elasticsearch" 2>/dev/null | cut -f1 || echo absent))"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  install|do_install)     parse_args "$@"; do_install ;;
  uninstall|do_uninstall) do_uninstall ;;
  purge)                  do_purge ;;
  status)                 do_status ;;
  *) usage; exit 2 ;;
esac
