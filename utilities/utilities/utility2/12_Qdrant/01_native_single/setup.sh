#!/usr/bin/env bash
# DOKANDAR utility — Qdrant 1.18 · native single-node vector DB, env-file driven.
# Installs the official static binary, runs it under systemd, auto-generates an API key (enforced on the
# REST/gRPC API), binds the ports, and saves the key to .env. The built-in /dashboard is the browser UI.
# Data under ${DATA_ROOT}/qdrant.  Usage:
#   sudo bash setup.sh install [--gen-key|--key KEY] | uninstall | purge | status
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
set -a; [ -f /etc/dokandar/.env ] && . /etc/dokandar/.env; [ -f "$ENV_FILE" ] && . "$ENV_FILE"; set +a
: "${DATA_ROOT:=/data}"; : "${QDRANT_VERSION:=1.18.2}"
: "${QDRANT_HTTP_PORT:=6333}"; : "${QDRANT_GRPC_PORT:=6334}"; : "${QDRANT_HOST:=0.0.0.0}"
DATA_DIR="${DATA_ROOT}/qdrant"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: sudo bash setup.sh install [--gen-key|--key KEY] | uninstall | purge | status"; }
gen_pw(){ local s; s="$(od -An -tx1 -N18 /dev/urandom | tr -dc 'a-f0-9')"; printf '%s' "${s:0:24}"; }  # SIGPIPE-safe
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (API key shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "============ Qdrant ${QDRANT_VERSION} (native) — connection details ============"; printf '%s' "$(_c 0)"
  cat <<SUM
  REST / HTTP    : http://${host}:${QDRANT_HTTP_PORT}   (binds ${QDRANT_HOST})
  gRPC API       : ${host}:${QDRANT_GRPC_PORT}
  API key        : ${QDRANT_API_KEY}   (header: api-key: <key>)
  Browser UI     : http://${host}:${QDRANT_HTTP_PORT}/dashboard   (built-in — paste the key in Settings)
  curl smoke     : curl -s -H 'api-key: ${QDRANT_API_KEY}' http://${host}:${QDRANT_HTTP_PORT}/collections
  Test from afar : QDRANT_HOST=${host} QDRANT_API_KEY=${QDRANT_API_KEY} bash ../test.sh
  Data directory : ${DATA_DIR}
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "==============================================================================="; printf '%s' "$(_c 0)"
}

do_install(){
  step "1/4  Configuration + data dir"
  if [ -n "$CLI_KEY" ]; then QDRANT_API_KEY="$CLI_KEY"; ok "API key: set via --key"
  elif [ "$GEN_KEY" = 1 ] || [ -z "${QDRANT_API_KEY:-}" ]; then QDRANT_API_KEY="$(gen_pw)"; ok "API key: auto-generated (24-char)"
  else ok "API key: reused from .env"; fi
  set_env_var QDRANT_API_KEY "$QDRANT_API_KEY"; set_env_var QDRANT_HTTP_PORT "$QDRANT_HTTP_PORT"; set_env_var QDRANT_GRPC_PORT "$QDRANT_GRPC_PORT"
  mkdir -p "$DATA_DIR"
  if [ ! -L /var/lib/qdrant ]; then systemctl stop qdrant 2>/dev/null || true
    [ -d /var/lib/qdrant ] && cp -a /var/lib/qdrant/. "$DATA_DIR/" 2>/dev/null || true
    rm -rf /var/lib/qdrant; ln -sfn "$DATA_DIR" /var/lib/qdrant; fi
  ok "host=${QDRANT_HOST} http=${QDRANT_HTTP_PORT} grpc=${QDRANT_GRPC_PORT} auth=on data=${DATA_DIR}"

  step "2/4  Installing Qdrant ${QDRANT_VERSION} binary"
  if [ ! -x /usr/local/bin/qdrant ]; then
    apt-get install -y wget curl ca-certificates >/dev/null 2>&1 || true
    wget -qO /tmp/qdrant.tar.gz "https://github.com/qdrant/qdrant/releases/download/v${QDRANT_VERSION}/qdrant-x86_64-unknown-linux-gnu.tar.gz"
    tar -xzf /tmp/qdrant.tar.gz -C /usr/local/bin qdrant; rm -f /tmp/qdrant.tar.gz
  fi
  id qdrant >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin qdrant
  mkdir -p "$DATA_DIR/storage" "$DATA_DIR/snapshots"; chown -R qdrant:qdrant "$DATA_DIR"
  ok "binary: $(/usr/local/bin/qdrant --version 2>/dev/null | head -1)"

  step "3/4  systemd unit + start (API key enforced)"
  cat > /etc/systemd/system/qdrant.service <<UNIT
[Unit]
Description=Qdrant vector database
After=network.target
[Service]
User=qdrant
WorkingDirectory=${DATA_DIR}
Environment=QDRANT__STORAGE__STORAGE_PATH=${DATA_DIR}/storage
Environment=QDRANT__STORAGE__SNAPSHOTS_PATH=${DATA_DIR}/snapshots
Environment=QDRANT__SERVICE__HOST=${QDRANT_HOST}
Environment=QDRANT__SERVICE__HTTP_PORT=${QDRANT_HTTP_PORT}
Environment=QDRANT__SERVICE__GRPC_PORT=${QDRANT_GRPC_PORT}
Environment=QDRANT__SERVICE__API_KEY=${QDRANT_API_KEY}
ExecStart=/usr/local/bin/qdrant
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload; systemctl enable qdrant >/dev/null 2>&1 || true; systemctl restart qdrant >/dev/null 2>&1 || true
  printf '   waiting for the REST API'; local h=000
  for _ in $(seq 1 20); do h="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${QDRANT_HTTP_PORT}/readyz" 2>/dev/null || echo 000)"; [ "$h" = 200 ] && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  [ "$h" = 200 ] && ok "REST live on :${QDRANT_HTTP_PORT} (svc=$(systemctl is-active qdrant))" || warn "REST not answering yet"

  step "4/4  Verify the API key is enforced"
  local nokey withkey
  nokey="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${QDRANT_HTTP_PORT}/collections" 2>/dev/null || echo 000)"
  withkey="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "api-key: ${QDRANT_API_KEY}" "http://127.0.0.1:${QDRANT_HTTP_PORT}/collections" 2>/dev/null || echo 000)"
  { [ "$nokey" != 200 ] && [ "$withkey" = 200 ]; } && ok "auth enforced (/collections no-key=${nokey}, with-key=${withkey})" || warn "auth check: no-key=${nokey} with-key=${withkey}"
  print_summary
}

do_uninstall(){
  step "Stopping Qdrant — DATA PRESERVED at ${DATA_DIR}"
  systemctl stop qdrant >/dev/null 2>&1 || true; systemctl disable qdrant >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/qdrant.service; systemctl daemon-reload 2>/dev/null || true
  if [ -L /var/lib/qdrant ]; then rm -f /var/lib/qdrant; fi
  rm -f /usr/local/bin/qdrant
  ok "Qdrant removed. DATA PRESERVED at ${DATA_DIR} ($(du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo '?'))."
  warn "To remove the data too: sudo bash setup.sh purge"
}
do_purge(){ do_uninstall; rm -rf "$DATA_DIR" || true; userdel qdrant >/dev/null 2>&1 || true; ok "data dir + qdrant user removed — full wipe."; }

do_status(){
  : "${QDRANT_HTTP_PORT:=6333}"; : "${QDRANT_API_KEY:=}"
  printf 'qdrant     : %s\n' "$(systemctl is-active qdrant 2>/dev/null)"
  curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:${QDRANT_HTTP_PORT}/readyz" 2>/dev/null \
    && echo "readyz     : OK on :${QDRANT_HTTP_PORT}" || echo "readyz     : DOWN on :${QDRANT_HTTP_PORT}"
  local wk; wk="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "api-key: ${QDRANT_API_KEY}" "http://127.0.0.1:${QDRANT_HTTP_PORT}/collections" 2>/dev/null || echo 000)"
  echo "collections: ${wk} (with api-key; expect 200)"
  echo "data       : ${DATA_DIR} ($(du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
GEN_KEY=0; CLI_KEY=""                              # parse flags AFTER the subcommand is stripped
while [ $# -gt 0 ]; do case "$1" in
  --gen-key) GEN_KEY=1; shift;;
  --key) CLI_KEY="$2"; shift 2;;
  *) break;;
esac; done
case "$cmd" in
  install|do_install)     do_install ;;
  uninstall|do_uninstall) do_uninstall ;;
  purge)                  do_purge ;;
  status)                 do_status ;;
  *) usage; exit 2 ;;
esac
