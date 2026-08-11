#!/usr/bin/env bash
# DOKANDAR utility — Elastic APM 9.4 · native single-node · INTEGRATED STACK (NO Docker).
# Installs Elasticsearch + Kibana + APM Server (Elastic 9.x apt repo), all via systemd, wired together:
# APM Server (:8200) -> Elasticsearch (:9200) <- Kibana (:5601, the APM app). Auto-generates the ES
# password, the kibana_system password, and the APM secret token. Data under ${DATA_ROOT}/apm_stack.
#   Usage:  sudo bash setup.sh install [--gen-password] | uninstall | purge | status
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
set -a; [ -f /etc/dokandar/.env ] && . /etc/dokandar/.env; [ -f "$ENV_FILE" ] && . "$ENV_FILE"; set +a
: "${DATA_ROOT:=/data}"; : "${ELASTIC_VERSION:=9.4}"
: "${ES_HTTP_PORT:=9200}"; : "${APM_PORT:=8200}"; : "${KIBANA_PORT:=5601}"; : "${ES_JAVA_HEAP:=512m}"
ESDATA="$DATA_ROOT/apm_stack/es"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: sudo bash setup.sh install [--gen-password] | uninstall | purge | status"; }
gen_secret(){ printf '%s' "$( set +o pipefail
  { command -v openssl >/dev/null 2>&1 && openssl rand -base64 48 || head -c 256 /dev/urandom; } \
  | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"${1:-24}" )"; }
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }

GEN=0; [ "${1:-}" = --gen-password ] && GEN=1
resolve_creds(){
  if [ "$GEN" = 1 ] || [ -z "${ELASTIC_PASSWORD:-}" ]; then ELASTIC_PASSWORD="$(gen_secret)"; fi
  if [ "$GEN" = 1 ] || [ -z "${KIBANA_SYSTEM_PASSWORD:-}" ]; then KIBANA_SYSTEM_PASSWORD="$(gen_secret)"; fi
  [ -n "${APM_SECRET_TOKEN:-}" ] || APM_SECRET_TOKEN="$(gen_secret 32)"
  set_env_var ELASTIC_PASSWORD "$ELASTIC_PASSWORD"; set_env_var KIBANA_SYSTEM_PASSWORD "$KIBANA_SYSTEM_PASSWORD"
  set_env_var APM_SECRET_TOKEN "$APM_SECRET_TOKEN"
  set_env_var ES_HTTP_PORT "$ES_HTTP_PORT"; set_env_var APM_PORT "$APM_PORT"; set_env_var KIBANA_PORT "$KIBANA_PORT"
}

add_repo(){ install -d -m 0755 /etc/apt/keyrings
  [ -s /etc/apt/keyrings/elastic.gpg ] || wget -qO- https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --batch --yes --dearmor -o /etc/apt/keyrings/elastic.gpg
  echo "deb [signed-by=/etc/apt/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/9.x/apt stable main" > /etc/apt/sources.list.d/elastic-9.x.list; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (secrets shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "========= Elastic APM ${ELASTIC_VERSION} stack (native) — connection details ========="; printf '%s' "$(_c 0)"
  cat <<SUM
  APM ingest     : http://${host}:${APM_PORT}   (agents; Authorization: Bearer <secret_token>)
  APM secret tok : ${APM_SECRET_TOKEN}
  Elasticsearch  : http://${host}:${ES_HTTP_PORT}   (user elastic / ${ELASTIC_PASSWORD})
  Kibana (UI)    : http://${host}:${KIBANA_PORT}   (APM app at /app/apm)
  Test from afar : APM_HOST=${host} APM_SECRET_TOKEN=${APM_SECRET_TOKEN} ELASTIC_PASSWORD=${ELASTIC_PASSWORD} bash ../test.sh
  Data directory : ${ESDATA}
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "===================================================================================="; printf '%s' "$(_c 0)"
}

do_install(){
  resolve_creds
  step "1/6  Config + vm.max_map_count + Elastic 9.x apt repo"
  sysctl -w vm.max_map_count=262144 >/dev/null 2>&1 || true; echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-dokandar-apm.conf
  mkdir -p "$ESDATA"; apt-get install -y wget gnupg curl ca-certificates apt-transport-https >/dev/null 2>&1 || true
  add_repo; apt-get update -y >/dev/null
  ok "repo added, es-data=${ESDATA}"

  step "2/6  Installing elasticsearch + kibana + apm-server"
  apt-get install -y "elasticsearch=${ELASTIC_VERSION}.*" >/dev/null 2>&1 || apt-get install -y elasticsearch >/dev/null
  apt-get install -y "kibana=${ELASTIC_VERSION}.*" >/dev/null 2>&1 || apt-get install -y kibana >/dev/null
  apt-get install -y apm-server >/dev/null
  ok "installed ES=$(dpkg-query -W -f='${Version}' elasticsearch 2>/dev/null) Kibana + apm-server"

  step "3/6  Elasticsearch (security on, http TLS off) + set elastic & kibana_system passwords"
  if [ ! -L /var/lib/elasticsearch ]; then systemctl stop elasticsearch 2>/dev/null || true; [ -d /var/lib/elasticsearch ] && cp -a /var/lib/elasticsearch/. "$ESDATA/" 2>/dev/null || true; rm -rf /var/lib/elasticsearch; ln -sfn "$ESDATA" /var/lib/elasticsearch; fi
  chown -R elasticsearch:elasticsearch "$ESDATA" 2>/dev/null || true
  mkdir -p /etc/elasticsearch/jvm.options.d; printf -- '-Xms%s\n-Xmx%s\n' "$ES_JAVA_HEAP" "$ES_JAVA_HEAP" > /etc/elasticsearch/jvm.options.d/heap.options
  sed -i '/BEGIN SECURITY AUTO CONFIGURATION/,/END SECURITY AUTO CONFIGURATION/d' /etc/elasticsearch/elasticsearch.yml 2>/dev/null || true
  sed -i '/^# >>> dokandar managed >>>/,/^# <<< dokandar managed <<</d' /etc/elasticsearch/elasticsearch.yml 2>/dev/null || true
  sed -i -E '/^[[:space:]]*(cluster\.name|network\.host|http\.port|discovery\.type|xpack\.security)([.a-z]*)?[[:space:]]*:/d' /etc/elasticsearch/elasticsearch.yml 2>/dev/null || true
  { echo "# >>> dokandar managed >>>"; echo "cluster.name: dokandar-apm"; echo "network.host: 0.0.0.0"; echo "http.port: ${ES_HTTP_PORT}"; echo "discovery.type: single-node";
    echo "xpack.security.enabled: true"; echo "xpack.security.http.ssl.enabled: false"; echo "xpack.security.transport.ssl.enabled: false"; echo "# <<< dokandar managed <<<"; } >> /etc/elasticsearch/elasticsearch.yml
  systemctl daemon-reload; systemctl enable --now elasticsearch >/dev/null 2>&1 || true
  printf '   waiting for ES'; for _ in $(seq 1 40); do curl -s --max-time 3 "http://localhost:${ES_HTTP_PORT}" >/dev/null 2>&1 && { echo ' ✓'; break; }; printf '.'; sleep 3; done
  local BOOT=""; for _ in $(seq 1 20); do BOOT="$(/usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -a -b -s 2>/dev/null | tr -d '[:space:]')"; [ -n "$BOOT" ] && break; sleep 3; done
  [ -n "$BOOT" ] && curl -s -u "elastic:$BOOT" -X POST "http://localhost:${ES_HTTP_PORT}/_security/user/elastic/_password" -H 'content-type: application/json' -d "{\"password\":\"${ELASTIC_PASSWORD}\"}" >/dev/null 2>&1 || true
  curl -s -u "elastic:${ELASTIC_PASSWORD}" -X POST "http://localhost:${ES_HTTP_PORT}/_security/user/kibana_system/_password" -H 'content-type: application/json' -d "{\"password\":\"${KIBANA_SYSTEM_PASSWORD}\"}" >/dev/null 2>&1 || true
  ok "ES up; elastic + kibana_system passwords set"

  step "4/6  Kibana -> Elasticsearch (kibana_system)"
  { echo "server.host: \"0.0.0.0\""; echo "server.port: ${KIBANA_PORT}"; echo "elasticsearch.hosts: [\"http://localhost:${ES_HTTP_PORT}\"]";
    echo "elasticsearch.username: \"kibana_system\""; echo "elasticsearch.password: \"${KIBANA_SYSTEM_PASSWORD}\""; } >> /etc/kibana/kibana.yml
  systemctl enable --now kibana >/dev/null 2>&1 || true
  ok "kibana configured + started (boots in ~1 min)"

  step "5/6  APM Server -> Elasticsearch (:${APM_PORT})"
  local YML=/etc/apm-server/apm-server.yml
  sed -i -E "s|^([[:space:]]*)host:[[:space:]]*\"?[^\"]*:[0-9]+\"?[[:space:]]*\$|\1host: \"0.0.0.0:${APM_PORT}\"|" "$YML" 2>/dev/null || true
  sed -i -E "s|^([[:space:]]*)hosts:[[:space:]]*\[\"localhost:9200\"\][[:space:]]*\$|\1hosts: [\"localhost:${ES_HTTP_PORT}\"]|" "$YML" 2>/dev/null || true
  grep -qE '^apm-server\.auth\.secret_token:' "$YML" || printf '\napm-server.auth.secret_token: "%s"\n' "$APM_SECRET_TOKEN" >> "$YML"
  grep -qE '^output\.elasticsearch\.username:' "$YML" || printf 'output.elasticsearch.username: "elastic"\n' >> "$YML"
  grep -qE '^output\.elasticsearch\.password:' "$YML" || printf 'output.elasticsearch.password: "%s"\n' "$ELASTIC_PASSWORD" >> "$YML"
  systemctl enable --now apm-server >/dev/null 2>&1 || true; sleep 5
  curl -s --max-time 5 "http://localhost:${APM_PORT}/" 2>/dev/null | grep -q version && ok "APM Server ingest reachable on :${APM_PORT}" || warn "apm-server warming up"

  step "6/6  Done"
  print_summary
}

do_uninstall(){
  step "Stopping + purging ES + Kibana + APM Server — DATA PRESERVED at ${ESDATA}"
  systemctl stop apm-server kibana elasticsearch >/dev/null 2>&1 || true
  [ -L /var/lib/elasticsearch ] && rm -f /var/lib/elasticsearch
  apt-get purge -y apm-server kibana elasticsearch >/dev/null 2>&1 || true; apt-get autoremove --purge -y >/dev/null 2>&1 || true
  rm -rf /etc/elasticsearch /etc/kibana /etc/apm-server /var/log/elasticsearch /var/log/kibana /var/log/apm-server
  rm -f /etc/apt/sources.list.d/elastic-9.x.list /etc/sysctl.d/99-dokandar-apm.conf
  apt-get update -y >/dev/null 2>&1 || true
  ok "stack removed. DATA PRESERVED at ${ESDATA}."
  warn "To remove the data too: sudo bash setup.sh purge"
}
do_purge(){ do_uninstall; rm -rf "$DATA_ROOT/apm_stack" || true; ok "data dir removed — full wipe."; }
do_status(){
  for s in elasticsearch kibana apm-server; do printf '%-14s: %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"; done
  echo "data dir      : ${ESDATA} ($(du -sh "$ESDATA" 2>/dev/null | cut -f1 || echo absent))"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  install|do_install)     do_install ;;
  uninstall|do_uninstall) do_uninstall ;;
  purge)                  do_purge ;;
  status)                 do_status ;;
  *) usage; exit 2 ;;
esac
