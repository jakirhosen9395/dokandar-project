#!/usr/bin/env bash
# DOKANDAR utility — Neo4j 2026.x Community · Docker Compose single-node · lifecycle wrapper.
# Auto-generates the password (saved to .env), brings the container up, verifies a Cypher query over HTTP.
# Data is a HOST bind mount (${DATA_ROOT}/neo4j_docker) and SURVIVES `docker compose down -v`.
#   Usage:  bash setup.sh up [--password P|--gen-password] | down | purge | status | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${NEO4J_HTTP_PORT:=7474}"; : "${NEO4J_BOLT_PORT:=7687}"; : "${NEO4J_USER:=neo4j}"
DATA_DIR="${DATA_ROOT}/neo4j_docker"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up [--password P|--gen-password] | down | purge | status | logs"; }
gen_pw(){ local s; s="$(od -An -tx1 -N18 /dev/urandom | tr -dc 'a-f0-9')"; printf '%s' "${s:0:24}"; }  # SIGPIPE-safe, >=8 chars
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true; export "${k}=${v}"
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }
hq(){ curl -s --max-time 12 -u "${NEO4J_USER}:${NEO4J_PASSWORD}" -H 'content-type: application/json' "http://127.0.0.1:${NEO4J_HTTP_PORT}/db/neo4j/tx/commit" -d '{"statements":[{"statement":"RETURN 1"}]}' 2>/dev/null; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (password shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "============ Neo4j (Docker, Community) — connection details ============"; printf '%s' "$(_c 0)"
  cat <<SUM
  HTTP / Browser : http://${host}:${NEO4J_HTTP_PORT}   (built-in Neo4j Browser — log in with the creds)
  Bolt endpoint  : bolt://${host}:${NEO4J_BOLT_PORT}
  Username       : ${NEO4J_USER}
  Password       : ${NEO4J_PASSWORD}
  Test from afar : NEO4J_HOST=${host} NEO4J_HTTP_PORT=${NEO4J_HTTP_PORT} NEO4J_USER=${NEO4J_USER} NEO4J_PASSWORD=${NEO4J_PASSWORD} bash ../test.sh
  Data (host)    : ${DATA_DIR}   (bind mount — survives 'down -v')
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "======================================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  step "1/3  Resolve credentials + bind-mount data dir"
  if [ -n "$CLI_PW" ]; then NEO4J_PASSWORD="$CLI_PW"; ok "password: set via --password"
  elif [ "$GEN_PW" = 1 ] || [ -z "${NEO4J_PASSWORD:-}" ]; then NEO4J_PASSWORD="$(gen_pw)"; ok "password: auto-generated (24-char)"
  else ok "password: reused from .env"; fi
  set_env_var NEO4J_USER "$NEO4J_USER"; set_env_var NEO4J_PASSWORD "$NEO4J_PASSWORD"
  set_env_var NEO4J_HTTP_PORT "$NEO4J_HTTP_PORT"; set_env_var NEO4J_BOLT_PORT "$NEO4J_BOLT_PORT"
  sudo mkdir -p "$DATA_DIR"; sudo chown -R 7474:7474 "$DATA_DIR" 2>/dev/null || true   # neo4j uid in the image

  step "2/3  docker compose up -d"
  docker compose up -d
  printf '   waiting for the HTTP API'; local h=000
  for _ in $(seq 1 40); do h="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${NEO4J_HTTP_PORT}/" 2>/dev/null || echo 000)"; { [ "$h" = 200 ] || [ "$h" = 303 ]; } && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  [ "$h" = 200 ] || [ "$h" = 303 ] && ok "HTTP live on :${NEO4J_HTTP_PORT}" || warn "HTTP not answering yet"

  step "3/3  Verify credentials end-to-end (RETURN 1)"
  local one=""
  for _ in $(seq 1 10); do one="$(hq | grep -oE '"row":\[1\]' | head -1)"; [ -n "$one" ] && break; sleep 2; done
  [ -n "$one" ] && ok "query OK — RETURN 1 -> 1" || warn "query failed (warming up?)"
  docker compose ps; print_summary
}

do_down(){ docker compose down; echo "Container removed. DATA PRESERVED at ${DATA_DIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$DATA_DIR"; echo "Full wipe: container + ${DATA_DIR} removed."; }
do_status(){ docker compose ps || true
  local h; h="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${NEO4J_HTTP_PORT}/" 2>/dev/null || echo 000)"
  { [ "$h" = 200 ] || [ "$h" = 303 ]; } && echo "HTTP       : OK on :${NEO4J_HTTP_PORT}" || echo "HTTP       : DOWN on :${NEO4J_HTTP_PORT}"
  echo "data (host): ${DATA_DIR} ($(sudo du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"; }
do_logs(){ docker compose logs --tail=80 -f; }

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
GEN_PW=0; CLI_PW=""                                # parse flags AFTER the subcommand is stripped
while [ $# -gt 0 ]; do case "$1" in
  --gen-password) GEN_PW=1; shift;;
  --password) CLI_PW="$2"; shift 2;;
  *) break;;
esac; done
case "$cmd" in
  up|install)     do_up ;;
  down|uninstall) do_down ;;
  purge)          do_purge ;;
  status)         do_status ;;
  logs)           do_logs ;;
  *) usage; exit 2 ;;
esac
