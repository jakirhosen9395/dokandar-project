#!/usr/bin/env bash
# DOKANDAR utility — Temporal · native single-node (dev server), env-file driven.
# Installs the official Temporal CLI binary and runs `temporal server start-dev` under systemd with SQLite
# persistence and the built-in Web UI. No auth (dev server). The frontend gRPC is :7233, the Web UI :8233.
# Data under ${DATA_ROOT}/temporal.  Usage:  sudo bash setup.sh install | uninstall | purge | status
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
set -a; [ -f /etc/dokandar/.env ] && . /etc/dokandar/.env; [ -f "$ENV_FILE" ] && . "$ENV_FILE"; set +a
: "${DATA_ROOT:=/data}"
: "${TEMPORAL_GRPC_PORT:=7233}"; : "${TEMPORAL_UI_PORT:=8233}"; : "${TEMPORAL_BIND:=0.0.0.0}"; : "${TEMPORAL_NAMESPACE:=default}"
DATA_DIR="${DATA_ROOT}/temporal"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: sudo bash setup.sh install | uninstall | purge | status"; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details"
  printf '%s' "$(_c '1;36')"; echo "============ Temporal dev server (native) — connection details ============"; printf '%s' "$(_c 0)"
  cat <<SUM
  Frontend gRPC  : ${host}:${TEMPORAL_GRPC_PORT}   (default namespace: ${TEMPORAL_NAMESPACE})
  Browser UI     : http://${host}:${TEMPORAL_UI_PORT}   (built-in dev-server Web UI)
  Auth           : none (dev server)
  CLI smoke test : temporal operator cluster system --address ${host}:${TEMPORAL_GRPC_PORT}
  Test from afar : TEMPORAL_HOST=${host} TEMPORAL_GRPC_PORT=${TEMPORAL_GRPC_PORT} bash ../test.sh
  Persistence    : SQLite ${DATA_DIR}/temporal.db
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "==========================================================================="; printf '%s' "$(_c 0)"
}

do_install(){
  step "1/4  Configuration + data dir"
  mkdir -p "$DATA_DIR"
  ok "grpc=${TEMPORAL_GRPC_PORT} ui=${TEMPORAL_UI_PORT} bind=${TEMPORAL_BIND} namespace=${TEMPORAL_NAMESPACE} data=${DATA_DIR}"

  step "2/4  Installing the Temporal CLI binary"
  if [ ! -x /usr/local/bin/temporal ]; then
    apt-get install -y wget curl ca-certificates >/dev/null 2>&1 || true
    rm -rf /tmp/tdl; mkdir -p /tmp/tdl
    wget -qO /tmp/temporal.tgz "https://temporal.download/cli/archive/latest?platform=linux&arch=amd64"
    tar -xzf /tmp/temporal.tgz -C /tmp/tdl; install -m 0755 /tmp/tdl/temporal /usr/local/bin/temporal
    rm -rf /tmp/temporal.tgz /tmp/tdl
  fi
  id temporal >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin temporal
  chown -R temporal:temporal "$DATA_DIR"
  ok "$(/usr/local/bin/temporal --version 2>/dev/null | head -1)"

  step "3/4  systemd unit (temporal server start-dev, SQLite + UI) + start"
  cat > /etc/systemd/system/temporal.service <<UNIT
[Unit]
Description=Temporal dev server (start-dev)
After=network-online.target
Wants=network-online.target
[Service]
User=temporal
ExecStart=/usr/local/bin/temporal server start-dev --ip ${TEMPORAL_BIND} --port ${TEMPORAL_GRPC_PORT} --ui-ip ${TEMPORAL_BIND} --ui-port ${TEMPORAL_UI_PORT} --db-filename ${DATA_DIR}/temporal.db --namespace ${TEMPORAL_NAMESPACE} --log-level warn
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload; systemctl enable temporal >/dev/null 2>&1 || true; systemctl restart temporal >/dev/null 2>&1 || true

  step "4/4  Wait for the frontend + verify"
  printf '   waiting for the frontend'; local up=0
  for _ in $(seq 1 30); do /usr/local/bin/temporal operator namespace list --address "127.0.0.1:${TEMPORAL_GRPC_PORT}" >/dev/null 2>&1 && { echo ' ✓'; up=1; break; }; printf '.'; sleep 2; done
  [ "$up" = 1 ] && ok "frontend answering (svc=$(systemctl is-active temporal))" || warn "frontend not answering yet (svc=$(systemctl is-active temporal))"
  print_summary
}

do_uninstall(){
  step "Stopping Temporal — DATA PRESERVED at ${DATA_DIR}"
  systemctl stop temporal >/dev/null 2>&1 || true; systemctl disable temporal >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/temporal.service; systemctl daemon-reload 2>/dev/null || true
  rm -f /usr/local/bin/temporal
  ok "Temporal removed. DATA PRESERVED at ${DATA_DIR} ($(du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo '?'))."
  warn "To remove the data too: sudo bash setup.sh purge"
}
do_purge(){ do_uninstall; rm -rf "$DATA_DIR" || true; userdel temporal >/dev/null 2>&1 || true; ok "data dir + temporal user removed — full wipe."; }

do_status(){
  : "${TEMPORAL_GRPC_PORT:=7233}"; : "${TEMPORAL_UI_PORT:=8233}"
  printf 'temporal   : %s\n' "$(systemctl is-active temporal 2>/dev/null)"
  /usr/local/bin/temporal operator namespace list --address "127.0.0.1:${TEMPORAL_GRPC_PORT}" >/dev/null 2>&1 \
    && echo "frontend   : OK on :${TEMPORAL_GRPC_PORT}" || echo "frontend   : DOWN on :${TEMPORAL_GRPC_PORT}"
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${TEMPORAL_UI_PORT}/" 2>/dev/null | grep -qE '200|3..' && echo "web UI     : OK on :${TEMPORAL_UI_PORT}" || echo "web UI     : DOWN on :${TEMPORAL_UI_PORT}"
  echo "data       : ${DATA_DIR} ($(du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  install|do_install)     do_install ;;
  uninstall|do_uninstall) do_uninstall ;;
  purge)                  do_purge ;;
  status)                 do_status ;;
  *) usage; exit 2 ;;
esac
