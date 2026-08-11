#!/usr/bin/env bash
# DOKANDAR utility — RustFS · native single-node (no Docker), env-file driven.
# Installs the official static (musl) binary, runs it under systemd with the built-in console, auto-generates
# the S3 access (20 hex) + secret (40 hex) keys, and saves them to .env. S3-compatible object storage.
# Data under ${DATA_ROOT}/rustfs.  Usage:
#   sudo bash setup.sh install [--gen-keys|--access KEY|--secret KEY] | uninstall | purge | status
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
set -a; [ -f /etc/dokandar/.env ] && . /etc/dokandar/.env; [ -f "$ENV_FILE" ] && . "$ENV_FILE"; set +a
: "${DATA_ROOT:=/data}"; : "${RUSTFS_VERSION:=1.0.0-beta.8}"
: "${RUSTFS_API_PORT:=9000}"; : "${RUSTFS_CONSOLE_PORT:=9001}"; : "${RUSTFS_LISTEN:=0.0.0.0}"
DATA_DIR="${DATA_ROOT}/rustfs"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: sudo bash setup.sh install [--gen-keys|--access KEY|--secret KEY] | uninstall | purge | status"; }
genhex(){ local s; s="$(od -An -tx1 -N40 /dev/urandom | tr -dc 'a-f0-9')"; printf '%s' "${s:0:${1:-40}}"; }  # SIGPIPE-safe
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }
MC(){ docker run --rm -i --network host -e MC_HOST_rfs="http://${RUSTFS_ACCESS_KEY}:${RUSTFS_SECRET_KEY}@127.0.0.1:${RUSTFS_API_PORT}" minio/mc:latest --no-color "$@" 2>/dev/null; }

GEN=0; CLI_AK=""; CLI_SK=""

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (keys shown ONCE — copy them into your test env)"
  printf '%s' "$(_c '1;36')"; echo "============ RustFS ${RUSTFS_VERSION} (native) — connection details ============"; printf '%s' "$(_c 0)"
  cat <<SUM
  S3 endpoint    : http://${host}:${RUSTFS_API_PORT}
  Access key     : ${RUSTFS_ACCESS_KEY}
  Secret key     : ${RUSTFS_SECRET_KEY}
  Console UI     : http://${host}:${RUSTFS_CONSOLE_PORT}   (browser — log in with the keys above)
  Test from afar : RUSTFS_HOST=${host} RUSTFS_API_PORT=${RUSTFS_API_PORT} RUSTFS_ACCESS_KEY=${RUSTFS_ACCESS_KEY} RUSTFS_SECRET_KEY=${RUSTFS_SECRET_KEY} bash ../test.sh
  Data directory : ${DATA_DIR}
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "==============================================================================="; printf '%s' "$(_c 0)"
}

do_install(){
  step "1/4  Configuration + data dir"
  [ -n "$CLI_AK" ] && RUSTFS_ACCESS_KEY="$CLI_AK"; [ -n "$CLI_SK" ] && RUSTFS_SECRET_KEY="$CLI_SK"
  if [ "$GEN" = 1 ] || [ -z "${RUSTFS_ACCESS_KEY:-}" ]; then RUSTFS_ACCESS_KEY="$(genhex 20)"; ok "access key: generated (20 hex)"; else ok "access key: reused"; fi
  if [ "$GEN" = 1 ] || [ -z "${RUSTFS_SECRET_KEY:-}" ]; then RUSTFS_SECRET_KEY="$(genhex 40)"; ok "secret key: generated (40 hex)"; else ok "secret key: reused"; fi
  set_env_var RUSTFS_ACCESS_KEY "$RUSTFS_ACCESS_KEY"; set_env_var RUSTFS_SECRET_KEY "$RUSTFS_SECRET_KEY"
  set_env_var RUSTFS_API_PORT "$RUSTFS_API_PORT"; set_env_var RUSTFS_CONSOLE_PORT "$RUSTFS_CONSOLE_PORT"
  mkdir -p "$DATA_DIR"
  ok "api=${RUSTFS_API_PORT} console=${RUSTFS_CONSOLE_PORT} listen=${RUSTFS_LISTEN} data=${DATA_DIR}"

  step "2/4  Installing the RustFS ${RUSTFS_VERSION} binary (static musl)"
  if [ ! -x /usr/local/bin/rustfs ]; then
    apt-get install -y wget curl unzip ca-certificates >/dev/null 2>&1 || true
    rm -rf /tmp/rfsdl; mkdir -p /tmp/rfsdl
    wget -qO /tmp/rfsdl/r.zip "https://github.com/rustfs/rustfs/releases/download/${RUSTFS_VERSION}/rustfs-linux-x86_64-musl-v${RUSTFS_VERSION}.zip"
    unzip -oq /tmp/rfsdl/r.zip -d /tmp/rfsdl; install -m 0755 /tmp/rfsdl/rustfs /usr/local/bin/rustfs; rm -rf /tmp/rfsdl
  fi
  id rustfs >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin rustfs
  chown -R rustfs:rustfs "$DATA_DIR"
  ok "$(/usr/local/bin/rustfs --version 2>/dev/null | head -1)"

  step "3/4  systemd unit (server + console) + start"
  { printf 'RUSTFS_ACCESS_KEY=%s\n' "$RUSTFS_ACCESS_KEY"; printf 'RUSTFS_SECRET_KEY=%s\n' "$RUSTFS_SECRET_KEY"; } > /etc/default/rustfs
  chmod 600 /etc/default/rustfs
  cat > /etc/systemd/system/rustfs.service <<UNIT
[Unit]
Description=RustFS object storage
After=network-online.target
Wants=network-online.target
[Service]
User=rustfs
Group=rustfs
EnvironmentFile=/etc/default/rustfs
ExecStart=/usr/local/bin/rustfs server ${DATA_DIR} --address ${RUSTFS_LISTEN}:${RUSTFS_API_PORT} --console-enable --console-address ${RUSTFS_LISTEN}:${RUSTFS_CONSOLE_PORT}
Restart=on-failure
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload; systemctl enable rustfs >/dev/null 2>&1 || true; systemctl restart rustfs >/dev/null 2>&1 || true
  printf '   waiting for the S3 API'; local h=000
  for _ in $(seq 1 20); do h="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${RUSTFS_API_PORT}/health" 2>/dev/null || echo 000)"; [ "$h" = 200 ] && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  [ "$h" = 200 ] && ok "S3 API live on :${RUSTFS_API_PORT} (svc=$(systemctl is-active rustfs))" || warn "API not answering yet"

  step "4/4  Verify S3 credentials (mc ls)"
  MC ls rfs >/dev/null 2>&1 && ok "S3 keys valid — ListBuckets OK" || warn "ListBuckets failed (warming up?)"
  print_summary
}

do_uninstall(){
  step "Stopping RustFS — DATA PRESERVED at ${DATA_DIR}"
  systemctl stop rustfs >/dev/null 2>&1 || true; systemctl disable rustfs >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/rustfs.service /etc/default/rustfs; systemctl daemon-reload 2>/dev/null || true
  rm -f /usr/local/bin/rustfs
  ok "RustFS removed. DATA PRESERVED at ${DATA_DIR} ($(du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo '?'))."
  warn "To remove the data too: sudo bash setup.sh purge"
}
do_purge(){ do_uninstall; rm -rf "$DATA_DIR" || true; userdel rustfs >/dev/null 2>&1 || true; ok "data dir + rustfs user removed — full wipe."; }

do_status(){
  : "${RUSTFS_API_PORT:=9000}"; : "${RUSTFS_CONSOLE_PORT:=9001}"
  printf 'rustfs     : %s\n' "$(systemctl is-active rustfs 2>/dev/null)"
  curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:${RUSTFS_API_PORT}/health" 2>/dev/null \
    && echo "S3 API     : OK on :${RUSTFS_API_PORT}" || echo "S3 API     : DOWN on :${RUSTFS_API_PORT}"
  echo "data       : ${DATA_DIR} ($(du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
while [ $# -gt 0 ]; do case "$1" in
  --gen-keys) GEN=1; shift;;
  --access) CLI_AK="$2"; shift 2;;
  --secret) CLI_SK="$2"; shift 2;;
  *) break;;
esac; done
case "$cmd" in
  install|do_install)     do_install ;;
  uninstall|do_uninstall) do_uninstall ;;
  purge)                  do_purge ;;
  status)                 do_status ;;
  *) usage; exit 2 ;;
esac
