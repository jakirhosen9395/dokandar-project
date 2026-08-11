#!/usr/bin/env bash
# DOKANDAR utility — Neo4j 2026.x Community · native single-node graph DB, env-file driven.
# Installs from the official Neo4j apt repo, runs under systemd, auto-generates the `neo4j` user password
# (via neo4j-admin set-initial-password), binds HTTP + Bolt, saves the creds to .env. The built-in Neo4j
# Browser is the web UI. Data under ${DATA_ROOT}/neo4j.  Usage:
#   sudo bash setup.sh install [--password P|--gen-password] | uninstall | purge | status
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
set -a; [ -f /etc/dokandar/.env ] && . /etc/dokandar/.env; [ -f "$ENV_FILE" ] && . "$ENV_FILE"; set +a
: "${DATA_ROOT:=/data}"
: "${NEO4J_HTTP_PORT:=7474}"; : "${NEO4J_BOLT_PORT:=7687}"; : "${NEO4J_LISTEN_ADDRESS:=0.0.0.0}"; : "${NEO4J_USER:=neo4j}"
DATA_DIR="${DATA_ROOT}/neo4j"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: sudo bash setup.sh install [--password P|--gen-password] | uninstall | purge | status"; }
gen_pw(){ local s; s="$(od -An -tx1 -N18 /dev/urandom | tr -dc 'a-f0-9')"; printf '%s' "${s:0:24}"; }  # SIGPIPE-safe, >=8 chars
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (password shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "============ Neo4j ${NEO4J_VER:-2026.x} Community (native) — connection details ============"; printf '%s' "$(_c 0)"
  cat <<SUM
  HTTP / Browser : http://${host}:${NEO4J_HTTP_PORT}   (built-in Neo4j Browser — log in with the creds)
  Bolt endpoint  : bolt://${host}:${NEO4J_BOLT_PORT}
  Username       : ${NEO4J_USER}
  Password       : ${NEO4J_PASSWORD}
  Connection URL : bolt://${NEO4J_USER}:${NEO4J_PASSWORD}@${host}:${NEO4J_BOLT_PORT}
  cypher smoke   : cypher-shell -a bolt://${host}:${NEO4J_BOLT_PORT} -u ${NEO4J_USER} -p '${NEO4J_PASSWORD}' 'RETURN 1'
  Test from afar : NEO4J_HOST=${host} NEO4J_USER=${NEO4J_USER} NEO4J_PASSWORD=${NEO4J_PASSWORD} bash ../test.sh
  Data directory : ${DATA_DIR}
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "==============================================================================="; printf '%s' "$(_c 0)"
}

do_install(){
  step "1/5  Configuration"
  if [ -n "$CLI_PW" ]; then NEO4J_PASSWORD="$CLI_PW"; ok "password: set via --password"
  elif [ "$GEN_PW" = 1 ] || [ -z "${NEO4J_PASSWORD:-}" ]; then NEO4J_PASSWORD="$(gen_pw)"; ok "password: auto-generated (24-char)"
  else ok "password: reused from .env"; fi
  set_env_var NEO4J_USER "$NEO4J_USER"; set_env_var NEO4J_PASSWORD "$NEO4J_PASSWORD"
  set_env_var NEO4J_HTTP_PORT "$NEO4J_HTTP_PORT"; set_env_var NEO4J_BOLT_PORT "$NEO4J_BOLT_PORT"
  ok "http=${NEO4J_HTTP_PORT} bolt=${NEO4J_BOLT_PORT} bind=${NEO4J_LISTEN_ADDRESS} user=${NEO4J_USER}"

  step "2/5  Official Neo4j apt repo + install (Community 2026.x)"
  if ! command -v neo4j >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y wget gnupg curl ca-certificates apt-transport-https >/dev/null 2>&1
    mkdir -p /etc/apt/keyrings
    wget -qO- https://debian.neo4j.com/neotechnology.gpg.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/neo4j.gpg
    echo "deb [signed-by=/etc/apt/keyrings/neo4j.gpg] https://debian.neo4j.com stable latest" > /etc/apt/sources.list.d/neo4j.list
    apt-get update -y >/dev/null 2>&1
    apt-get install -y neo4j >/dev/null 2>&1
  fi
  NEO4J_VER="$(dpkg-query -W -f='${Version}' neo4j 2>/dev/null || true)"; ok "installed neo4j ${NEO4J_VER}"

  step "3/5  Data dir -> ${DATA_DIR} + network config"
  systemctl stop neo4j 2>/dev/null || true
  mkdir -p "$DATA_DIR"
  if [ ! -L /var/lib/neo4j/data ]; then
    [ -d /var/lib/neo4j/data ] && cp -a /var/lib/neo4j/data/. "$DATA_DIR/" 2>/dev/null || true
    rm -rf /var/lib/neo4j/data; ln -sfn "$DATA_DIR" /var/lib/neo4j/data
  fi
  chown -R neo4j:neo4j "$DATA_DIR" /var/lib/neo4j/data 2>/dev/null || true
  # config drop-ins (these keys override neo4j.conf)
  local CONF=/etc/neo4j/neo4j.conf
  sed -i -E '/^#?\s*(server\.default_listen_address|server\.bolt\.listen_address|server\.http\.listen_address|server\.bolt\.advertised_address|server\.http\.advertised_address)=/d' "$CONF"
  {
    echo "server.default_listen_address=${NEO4J_LISTEN_ADDRESS}"
    echo "server.bolt.listen_address=${NEO4J_LISTEN_ADDRESS}:${NEO4J_BOLT_PORT}"
    echo "server.http.listen_address=${NEO4J_LISTEN_ADDRESS}:${NEO4J_HTTP_PORT}"
  } >> "$CONF"
  ok "listen=${NEO4J_LISTEN_ADDRESS} http=${NEO4J_HTTP_PORT} bolt=${NEO4J_BOLT_PORT}; data -> ${DATA_DIR}"

  step "4/5  Set the initial password + start"
  # set-initial-password only works on a never-started db; safe on a fresh install (idempotent: ignore if already set)
  neo4j-admin dbms set-initial-password "$NEO4J_PASSWORD" >/dev/null 2>&1 || warn "initial password already set (reusing existing — pass the same one in .env)"
  systemctl enable neo4j >/dev/null 2>&1 || true; systemctl restart neo4j >/dev/null 2>&1 || true
  printf '   waiting for the HTTP API'; local h=000
  for _ in $(seq 1 30); do h="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${NEO4J_HTTP_PORT}/" 2>/dev/null || echo 000)"; { [ "$h" = 200 ] || [ "$h" = 303 ]; } && { echo ' ✓'; break; }; printf '.'; sleep 2; done

  step "5/5  Verify a Cypher query (RETURN 1)"
  local one; one="$(curl -s --max-time 10 -u "${NEO4J_USER}:${NEO4J_PASSWORD}" -H 'content-type: application/json' "http://127.0.0.1:${NEO4J_HTTP_PORT}/db/neo4j/tx/commit" -d '{"statements":[{"statement":"RETURN 1"}]}' 2>/dev/null | grep -oE '"row":\[1\]' | head -1)"
  [ -n "$one" ] && ok "query OK — RETURN 1 -> 1 (svc=$(systemctl is-active neo4j))" || warn "query did not answer yet (svc=$(systemctl is-active neo4j) — warming up?)"
  print_summary
}

do_uninstall(){
  step "Stopping Neo4j — DATA PRESERVED at ${DATA_DIR}"
  systemctl stop neo4j >/dev/null 2>&1 || true; systemctl disable neo4j >/dev/null 2>&1 || true
  apt-get purge -y neo4j >/dev/null 2>&1 || true; apt-get autoremove --purge -y >/dev/null 2>&1 || true
  rm -f /etc/apt/sources.list.d/neo4j.list /etc/apt/keyrings/neo4j.gpg
  rm -rf /etc/neo4j
  ok "Neo4j + config + repo removed. DATA PRESERVED at ${DATA_DIR} ($(du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo '?'))."
  warn "To remove the data too: sudo bash setup.sh purge"
}
do_purge(){ do_uninstall; rm -rf "$DATA_DIR" /var/lib/neo4j || true; ok "data dir removed — full wipe."; }

do_status(){
  : "${NEO4J_HTTP_PORT:=7474}"; : "${NEO4J_USER:=neo4j}"; : "${NEO4J_PASSWORD:=}"
  printf 'neo4j      : %s\n' "$(systemctl is-active neo4j 2>/dev/null)"
  local h; h="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${NEO4J_HTTP_PORT}/" 2>/dev/null || echo 000)"
  { [ "$h" = 200 ] || [ "$h" = 303 ]; } && echo "HTTP       : OK on :${NEO4J_HTTP_PORT} (Browser UI)" || echo "HTTP       : DOWN on :${NEO4J_HTTP_PORT}"
  local one; one="$(curl -s --max-time 8 -u "${NEO4J_USER}:${NEO4J_PASSWORD}" -H 'content-type: application/json' "http://127.0.0.1:${NEO4J_HTTP_PORT}/db/neo4j/tx/commit" -d '{"statements":[{"statement":"RETURN 1"}]}' 2>/dev/null | grep -oE '"row":\[1\]')"
  [ -n "$one" ] && echo "query      : OK (RETURN 1 -> 1)" || echo "query      : DOWN"
  echo "data       : ${DATA_DIR} ($(du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
GEN_PW=0; CLI_PW=""                                # parse flags AFTER the subcommand is stripped
while [ $# -gt 0 ]; do case "$1" in
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
