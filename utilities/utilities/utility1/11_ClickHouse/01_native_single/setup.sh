#!/usr/bin/env bash
# DOKANDAR utility — ClickHouse 26.3 LTS · native single-node OLAP, env-file driven.
# Installs from the official ClickHouse apt repo, runs under systemd, auto-generates the `default` user's
# password (a users.d drop-in), binds the HTTP + native ports, and saves the creds to .env. The built-in
# SQL console is the HTTP interface's /play. Data under ${DATA_ROOT}/clickhouse (symlinked).  Usage:
#   sudo bash setup.sh install [--user U] [--gen-password|--password P] | uninstall | purge | status
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
export HOME=/root GNUPGHOME=/root/.gnupg
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
set -a; [ -f /etc/dokandar/.env ] && . /etc/dokandar/.env; [ -f "$ENV_FILE" ] && . "$ENV_FILE"; set +a
: "${DATA_ROOT:=/data}"; : "${CH_VERSION_LINE:=26.3}"
: "${CLICKHOUSE_HTTP_PORT:=8123}"; : "${CLICKHOUSE_TCP_PORT:=9000}"
: "${CLICKHOUSE_LISTEN_HOST:=0.0.0.0}"; : "${CLICKHOUSE_USER:=default}"
DATA_DIR="${DATA_ROOT}/clickhouse"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: sudo bash setup.sh install [--user U] [--gen-password|--password P] | uninstall | purge | status"; }
gen_pw(){ local s; s="$(od -An -tx1 -N18 /dev/urandom | tr -dc 'a-f0-9')"; printf '%s' "${s:0:24}"; }  # SIGPIPE-safe
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (password shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "============ ClickHouse ${CH_VERSION_LINE} LTS (native) — connection details ============"; printf '%s' "$(_c 0)"
  cat <<SUM
  HTTP interface : http://${host}:${CLICKHOUSE_HTTP_PORT}   (binds ${CLICKHOUSE_LISTEN_HOST})
  Native TCP     : ${host}:${CLICKHOUSE_TCP_PORT}
  Username       : ${CLICKHOUSE_USER}
  Password       : ${CLICKHOUSE_PASSWORD}
  Browser UI     : http://${host}:${CLICKHOUSE_HTTP_PORT}/play   (built-in SQL console — no extra binary)
  curl smoke     : echo 'SELECT version()' | curl -s -u ${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD} http://${host}:${CLICKHOUSE_HTTP_PORT}/ --data-binary @-
  Test from afar : CLICKHOUSE_HOST=${host} CLICKHOUSE_USER=${CLICKHOUSE_USER} CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD} bash ../test.sh
  Data directory : ${DATA_DIR}
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "============================================================================="; printf '%s' "$(_c 0)"
}

do_install(){
  step "1/5  Configuration"
  if [ -n "$CLI_PW" ]; then CLICKHOUSE_PASSWORD="$CLI_PW"; ok "password: set via --password"
  elif [ "$GEN_PW" = 1 ] || [ -z "${CLICKHOUSE_PASSWORD:-}" ]; then CLICKHOUSE_PASSWORD="$(gen_pw)"; ok "password: auto-generated (24-char)"
  else ok "password: reused from .env"; fi
  set_env_var CLICKHOUSE_USER "$CLICKHOUSE_USER"; set_env_var CLICKHOUSE_PASSWORD "$CLICKHOUSE_PASSWORD"
  set_env_var CLICKHOUSE_HTTP_PORT "$CLICKHOUSE_HTTP_PORT"; set_env_var CLICKHOUSE_TCP_PORT "$CLICKHOUSE_TCP_PORT"
  ok "http=${CLICKHOUSE_HTTP_PORT} tcp=${CLICKHOUSE_TCP_PORT} listen=${CLICKHOUSE_LISTEN_HOST} user=${CLICKHOUSE_USER}"

  step "2/5  Data dir -> ${DATA_DIR} (symlink)"
  mkdir -p "$DATA_DIR"
  if [ ! -L /var/lib/clickhouse ]; then systemctl stop clickhouse-server 2>/dev/null || true
    [ -d /var/lib/clickhouse ] && cp -a /var/lib/clickhouse/. "$DATA_DIR/" 2>/dev/null || true
    rm -rf /var/lib/clickhouse; ln -sfn "$DATA_DIR" /var/lib/clickhouse; fi
  ok "data -> $DATA_DIR"

  step "3/5  Official apt repo + ClickHouse ${CH_VERSION_LINE} LTS"
  if ! command -v clickhouse-client >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl gnupg dirmngr ca-certificates apt-transport-https >/dev/null 2>&1
    mkdir -p /etc/apt/keyrings "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
    gpg --batch --keyserver keyserver.ubuntu.com --recv-keys 3A9EA1193A97B548BE1457D48919F6BD2B48D754 >/dev/null 2>&1
    gpg --batch --yes --export 3A9EA1193A97B548BE1457D48919F6BD2B48D754 > /etc/apt/keyrings/clickhouse.gpg
    chmod 0644 /etc/apt/keyrings/clickhouse.gpg
    echo "deb [signed-by=/etc/apt/keyrings/clickhouse.gpg] https://packages.clickhouse.com/deb stable main" > /etc/apt/sources.list.d/clickhouse.list
    apt-get update -y >/dev/null 2>&1
    local V; V="$(apt-cache madison clickhouse-server 2>/dev/null | awk '{print $3}' | grep -E "^${CH_VERSION_LINE}\." | head -1 || true)"
    # CRITICAL: the clickhouse postinst names the OS service user from $CLICKHOUSE_USER (${CLICKHOUSE_USER:-clickhouse}).
    # We exported CLICKHOUSE_USER (the SQL user, e.g. 'default') from .env — that would make the postinst create an OS
    # user 'default', but the systemd unit hardcodes User=clickhouse → won't start. Force the OS user back to clickhouse
    # for the install subprocess only (our SQL-user var is untouched and used for the users.d password below).
    if [ -n "$V" ]; then env CLICKHOUSE_USER=clickhouse CLICKHOUSE_GROUP=clickhouse apt-get install -y clickhouse-server="$V" clickhouse-client="$V" clickhouse-common-static="$V" >/dev/null 2>&1; ok "installed pinned ClickHouse $V"
    else env CLICKHOUSE_USER=clickhouse CLICKHOUSE_GROUP=clickhouse apt-get install -y clickhouse-server clickhouse-client >/dev/null 2>&1; warn "${CH_VERSION_LINE}.* not in repo — installed current stable"; fi
    id clickhouse >/dev/null 2>&1 && chown -R clickhouse:clickhouse "$DATA_DIR" 2>/dev/null || true
  else ok "clickhouse already installed ($(clickhouse-client --version 2>/dev/null | head -1))"; fi

  step "4/5  Config drop-ins (network + password)"
  mkdir -p /etc/clickhouse-server/config.d /etc/clickhouse-server/users.d
  cat > /etc/clickhouse-server/config.d/dokandar-network.xml <<XML
<clickhouse>
    <listen_host>${CLICKHOUSE_LISTEN_HOST}</listen_host>
    <http_port>${CLICKHOUSE_HTTP_PORT}</http_port>
    <tcp_port>${CLICKHOUSE_TCP_PORT}</tcp_port>
</clickhouse>
XML
  cat > /etc/clickhouse-server/users.d/dokandar-password.xml <<XML
<clickhouse>
    <users>
        <${CLICKHOUSE_USER}>
            <password>${CLICKHOUSE_PASSWORD}</password>
        </${CLICKHOUSE_USER}>
    </users>
</clickhouse>
XML
  ok "password set on '${CLICKHOUSE_USER}'; HTTP/native ports + listen_host applied"

  step "5/5  Start + verify (HTTP /play console included)"
  systemctl enable clickhouse-server >/dev/null 2>&1 || true
  systemctl restart clickhouse-server >/dev/null 2>&1 || true
  printf '   waiting for the HTTP interface'; local h=000
  for _ in $(seq 1 25); do h="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${CLICKHOUSE_HTTP_PORT}/ping" 2>/dev/null || echo 000)"; [ "$h" = 200 ] && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  local VER; VER="$(printf 'SELECT version()' | curl -s --max-time 10 -u "${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}" "http://127.0.0.1:${CLICKHOUSE_HTTP_PORT}/" --data-binary @- 2>/dev/null)"
  [ -n "$VER" ] && ok "query OK — version ${VER} (svc=$(systemctl is-active clickhouse-server))" || warn "query not answering yet (svc=$(systemctl is-active clickhouse-server))"
  print_summary
}

do_uninstall(){
  step "Stopping clickhouse-server — DATA PRESERVED at ${DATA_DIR}"
  systemctl stop clickhouse-server >/dev/null 2>&1 || true; systemctl disable clickhouse-server >/dev/null 2>&1 || true
  local PKGS; PKGS="$(dpkg-query -W -f='${Package} ' 'clickhouse*' 2>/dev/null || true)"
  apt-get purge -y $PKGS clickhouse-server clickhouse-client clickhouse-common-static >/dev/null 2>&1 || true
  apt-get autoremove --purge -y >/dev/null 2>&1 || true
  rm -rf /etc/clickhouse-server /etc/clickhouse-client /var/log/clickhouse-server
  rm -f /etc/apt/sources.list.d/clickhouse.list /etc/apt/keyrings/clickhouse.gpg
  if [ -L /var/lib/clickhouse ]; then rm -f /var/lib/clickhouse; fi
  ok "ClickHouse + config + repo removed. DATA PRESERVED at ${DATA_DIR} ($(du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo '?'))."
  warn "To remove the data too: sudo bash setup.sh purge"
}
do_purge(){ do_uninstall; rm -rf "$DATA_DIR" || true
  userdel clickhouse >/dev/null 2>&1 || true; groupdel clickhouse >/dev/null 2>&1 || true
  ok "data dir + clickhouse OS user removed — full wipe."; }

do_status(){
  : "${CLICKHOUSE_HTTP_PORT:=8123}"; : "${CLICKHOUSE_USER:=default}"; : "${CLICKHOUSE_PASSWORD:=}"
  printf 'clickhouse-server : %s\n' "$(systemctl is-active clickhouse-server 2>/dev/null)"
  curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:${CLICKHOUSE_HTTP_PORT}/ping" 2>/dev/null \
    && echo "HTTP /ping        : OK on :${CLICKHOUSE_HTTP_PORT} (/play console live)" || echo "HTTP /ping        : DOWN on :${CLICKHOUSE_HTTP_PORT}"
  local VER; VER="$(printf 'SELECT version()' | curl -s --max-time 8 -u "${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}" "http://127.0.0.1:${CLICKHOUSE_HTTP_PORT}/" --data-binary @- 2>/dev/null)"
  [ -n "$VER" ] && echo "query             : OK (version ${VER})" || echo "query             : DOWN"
  echo "data              : ${DATA_DIR} ($(du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
GEN_PW=0; CLI_PW=""                                # parse flags AFTER the subcommand is stripped
while [ $# -gt 0 ]; do case "$1" in
  --user) CLICKHOUSE_USER="$2"; shift 2;;
  --gen-password) GEN_PW=1; shift;;
  --password) CLI_PW="$2"; shift 2;;
  *) break;;
esac; done
case "$cmd" in
  install|do_install)     do_install ;;
  uninstall|do_uninstall) do_uninstall ;;
  purge)                  do_purge ;;
  status)                 do_status ;;
  *) usage; exit 2 ;;
esac
