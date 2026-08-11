#!/usr/bin/env bash
# DOKANDAR utility — NATS JetStream 2.14 · native single-node, env-file driven.
# Installs the official nats-server binary, runs it under systemd with JetStream ON and an auto-generated
# auth token, binds client + monitoring ports, and saves the token to .env. NATS has NO browser UI (:8222
# serves JSON monitoring). JetStream store under ${DATA_ROOT}/nats.  Usage:
#   sudo bash setup.sh install [--gen-token|--token T] | uninstall | purge | status
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
set -a; [ -f /etc/dokandar/.env ] && . /etc/dokandar/.env; [ -f "$ENV_FILE" ] && . "$ENV_FILE"; set +a
: "${DATA_ROOT:=/data}"; : "${NATS_VERSION:=2.14.2}"
: "${NATS_HOST:=0.0.0.0}"; : "${NATS_CLIENT_PORT:=4222}"; : "${NATS_MONITOR_PORT:=8222}"
DATA_DIR="${DATA_ROOT}/nats"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: sudo bash setup.sh install [--gen-token|--token T] | uninstall | purge | status"; }
gen_pw(){ local s; s="$(od -An -tx1 -N18 /dev/urandom | tr -dc 'a-f0-9')"; printf '%s' "${s:0:24}"; }  # SIGPIPE-safe
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (token shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "============ NATS JetStream ${NATS_VERSION} (native) — connection details ============"; printf '%s' "$(_c 0)"
  cat <<SUM
  Client URL     : nats://${NATS_AUTH_TOKEN}@${host}:${NATS_CLIENT_PORT}   (token auth)
  Client bind    : ${NATS_HOST}:${NATS_CLIENT_PORT}   (JetStream ON)
  Auth token     : ${NATS_AUTH_TOKEN}
  Monitoring     : http://${host}:${NATS_MONITOR_PORT}/healthz  (JSON; also /varz /jsz — NO HTML UI)
  nats CLI smoke : nats -s nats://${NATS_AUTH_TOKEN}@${host}:${NATS_CLIENT_PORT} account info
  Test from afar : NATS_HOST=${host} NATS_AUTH_TOKEN=${NATS_AUTH_TOKEN} bash ../test.sh
  JetStream store: ${DATA_DIR}/jetstream
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "==================================================================================="; printf '%s' "$(_c 0)"
}

do_install(){
  step "1/5  Configuration + data dir"
  if [ -n "$CLI_TOK" ]; then NATS_AUTH_TOKEN="$CLI_TOK"; ok "token: set via --token"
  elif [ "$GEN_TOK" = 1 ] || [ -z "${NATS_AUTH_TOKEN:-}" ]; then NATS_AUTH_TOKEN="$(gen_pw)"; ok "token: auto-generated (24-char)"
  else ok "token: reused from .env"; fi
  set_env_var NATS_AUTH_TOKEN "$NATS_AUTH_TOKEN"; set_env_var NATS_CLIENT_PORT "$NATS_CLIENT_PORT"; set_env_var NATS_MONITOR_PORT "$NATS_MONITOR_PORT"
  mkdir -p "$DATA_DIR/jetstream"
  ok "client=${NATS_CLIENT_PORT} monitor=${NATS_MONITOR_PORT} jetstream=on auth=token data=${DATA_DIR}"

  step "2/5  Installing nats-server ${NATS_VERSION}"
  if [ ! -x /usr/local/bin/nats-server ]; then
    apt-get install -y wget curl ca-certificates >/dev/null 2>&1 || true
    rm -rf /tmp/natsdl; mkdir -p /tmp/natsdl
    wget -qO /tmp/nats.tgz "https://github.com/nats-io/nats-server/releases/download/v${NATS_VERSION}/nats-server-v${NATS_VERSION}-linux-amd64.tar.gz"
    tar -xzf /tmp/nats.tgz -C /tmp/natsdl; install -m 0755 "/tmp/natsdl/nats-server-v${NATS_VERSION}-linux-amd64/nats-server" /usr/local/bin/nats-server
    rm -rf /tmp/nats.tgz /tmp/natsdl
  fi
  id nats >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin nats
  chown -R nats:nats "$DATA_DIR"
  ok "$(/usr/local/bin/nats-server --version 2>/dev/null | head -1)"

  step "3/5  Config (JetStream + token) + systemd"
  mkdir -p /etc/nats
  cat > /etc/nats/nats.conf <<CONF
listen: ${NATS_HOST}:${NATS_CLIENT_PORT}
http: ${NATS_HOST}:${NATS_MONITOR_PORT}
server_name: dokandar-nats-1
jetstream {
  store_dir: "${DATA_DIR}/jetstream"
}
authorization {
  token: "${NATS_AUTH_TOKEN}"
}
CONF
  chmod 640 /etc/nats/nats.conf; chown root:nats /etc/nats/nats.conf
  cat > /etc/systemd/system/nats.service <<UNIT
[Unit]
Description=NATS JetStream server
After=network-online.target
Wants=network-online.target
[Service]
User=nats
ExecStart=/usr/local/bin/nats-server -c /etc/nats/nats.conf
Restart=on-failure
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload; systemctl enable nats >/dev/null 2>&1 || true; systemctl restart nats >/dev/null 2>&1 || true

  step "4/5  Wait for the monitoring endpoint"
  printf '   waiting for :%s/healthz' "$NATS_MONITOR_PORT"; local h=000
  for _ in $(seq 1 20); do h="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${NATS_MONITOR_PORT}/healthz" 2>/dev/null || echo 000)"; [ "$h" = 200 ] && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  [ "$h" = 200 ] && ok "healthz OK (svc=$(systemctl is-active nats))" || warn "healthz not answering yet (svc=$(systemctl is-active nats))"

  step "5/5  Verify JetStream is enabled"
  curl -fsS --max-time 5 "http://127.0.0.1:${NATS_MONITOR_PORT}/healthz?js-enabled-only=true" >/dev/null 2>&1 \
    && ok "JetStream enabled (healthz?js-enabled-only=true OK)" || warn "JetStream check failed"
  print_summary
}

do_uninstall(){
  step "Stopping NATS — DATA PRESERVED at ${DATA_DIR}"
  systemctl stop nats >/dev/null 2>&1 || true; systemctl disable nats >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/nats.service; systemctl daemon-reload 2>/dev/null || true
  rm -f /usr/local/bin/nats-server; rm -rf /etc/nats
  ok "NATS removed. DATA PRESERVED at ${DATA_DIR} ($(du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo '?'))."
  warn "To remove the data too: sudo bash setup.sh purge"
}
do_purge(){ do_uninstall; rm -rf "$DATA_DIR" || true; userdel nats >/dev/null 2>&1 || true; ok "data dir + nats user removed — full wipe."; }

do_status(){
  : "${NATS_MONITOR_PORT:=8222}"
  printf 'nats       : %s\n' "$(systemctl is-active nats 2>/dev/null)"
  curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:${NATS_MONITOR_PORT}/healthz" 2>/dev/null \
    && echo "healthz    : OK on :${NATS_MONITOR_PORT}" || echo "healthz    : DOWN on :${NATS_MONITOR_PORT}"
  curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:${NATS_MONITOR_PORT}/healthz?js-enabled-only=true" 2>/dev/null \
    && echo "jetstream  : enabled" || echo "jetstream  : not ready"
  echo "data       : ${DATA_DIR} ($(du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
GEN_TOK=0; CLI_TOK=""                              # parse flags AFTER the subcommand is stripped
while [ $# -gt 0 ]; do case "$1" in
  --gen-token) GEN_TOK=1; shift;;
  --token) CLI_TOK="$2"; shift 2;;
  *) break;;
esac; done
case "$cmd" in
  install|do_install)     do_install ;;
  uninstall|do_uninstall) do_uninstall ;;
  purge)                  do_purge ;;
  status)                 do_status ;;
  *) usage; exit 2 ;;
esac
