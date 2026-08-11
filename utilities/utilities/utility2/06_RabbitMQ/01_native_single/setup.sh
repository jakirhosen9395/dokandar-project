#!/usr/bin/env bash
# DOKANDAR utility — RabbitMQ 4.x · native single-node (NO Docker), env-file driven.
# Auth ON (admin user, guest deleted); auto-generates a COMPLEX password when none is set; --gen-password
# rotates. The Management plugin (built-in web UI + HTTP API) is enabled on :15672. Data under
# ${DATA_ROOT}/rabbitmq (preserved on uninstall; `purge` wipes). Prints credentials at the end.
#   Usage:  sudo bash setup.sh install [--user U] [--password P | --gen-password] | uninstall | purge | status
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
set -a; [ -f /etc/dokandar/.env ] && . /etc/dokandar/.env; [ -f "$ENV_FILE" ] && . "$ENV_FILE"; set +a
: "${DATA_ROOT:=/data}"
: "${RABBITMQ_AMQP_PORT:=5672}"; : "${RABBITMQ_MGMT_PORT:=15672}"; : "${RABBITMQ_NODE_IP:=0.0.0.0}"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: sudo bash setup.sh install [--user U] [--password P | --gen-password] | uninstall | purge | status"; }

gen_password(){ printf '%s' "$( set +o pipefail
  { command -v openssl >/dev/null 2>&1 && openssl rand -base64 48 || head -c 256 /dev/urandom; } \
  | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24 )"; }
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }

USER_ARG=""; PASS_ARG=""; GEN=0
parse_args(){ while [ $# -gt 0 ]; do case "$1" in
    --user) USER_ARG="${2:?}"; shift 2;; --user=*) USER_ARG="${1#*=}"; shift;;
    --password) PASS_ARG="${2:?}"; shift 2;; --password=*) PASS_ARG="${1#*=}"; shift;;
    --gen-password) GEN=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1"; usage; exit 2;;
  esac; done; }

resolve_creds(){
  USER_="${USER_ARG:-${RABBITMQ_DEFAULT_USER:-dokandar}}"
  if   [ -n "$PASS_ARG" ];                   then PASS_="$PASS_ARG";              PW_SRC="provided (--password)"
  elif [ "$GEN" = 1 ];                       then PASS_="$(gen_password)";        PW_SRC="auto-generated (--gen-password)"
  elif [ -n "${RABBITMQ_DEFAULT_PASS:-}" ];  then PASS_="$RABBITMQ_DEFAULT_PASS"; PW_SRC="reused from .env"
  else                                            PASS_="$(gen_password)";        PW_SRC="auto-generated (.env was empty)"
  fi
  set_env_var RABBITMQ_DEFAULT_USER "$USER_"; set_env_var RABBITMQ_DEFAULT_PASS "$PASS_"
  set_env_var RABBITMQ_AMQP_PORT "$RABBITMQ_AMQP_PORT"; set_env_var RABBITMQ_MGMT_PORT "$RABBITMQ_MGMT_PORT"
}

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (password shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "================ RabbitMQ 4.x (native) — connection details ================"; printf '%s' "$(_c 0)"
  cat <<SUM
  AMQP endpoint  : ${host}:${RABBITMQ_AMQP_PORT}   (binds ${RABBITMQ_NODE_IP})
  User           : ${USER_}   (administrator; guest deleted)
  Password       : ${PASS_}   [${PW_SRC}]
  AMQP URL       : amqp://${USER_}:${PASS_}@${host}:${RABBITMQ_AMQP_PORT}/
  Browser UI     : http://${host}:${RABBITMQ_MGMT_PORT}   (Management plugin — log in with the above)
  HTTP API       : http://${USER_}:${PASS_}@${host}:${RABBITMQ_MGMT_PORT}/api/overview
  Test from afar : bash ../test.sh "http://${USER_}:${PASS_}@${host}:${RABBITMQ_MGMT_PORT}"
  Data directory : ${DATA_ROOT}/rabbitmq
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "============================================================================"; printf '%s' "$(_c 0)"
}

do_install(){
  resolve_creds
  step "1/5  Configuration"
  ok "user=${USER_} amqp=${RABBITMQ_AMQP_PORT} mgmt=${RABBITMQ_MGMT_PORT} bind=${RABBITMQ_NODE_IP} password=${PW_SRC}"

  step "2/5  Data dir (/var/lib/rabbitmq -> ${DATA_ROOT}/rabbitmq) — non-destructive"
  mkdir -p "$DATA_ROOT/rabbitmq"
  if [ ! -L /var/lib/rabbitmq ]; then
    systemctl stop rabbitmq-server 2>/dev/null || true
    [ -d /var/lib/rabbitmq ] && cp -a /var/lib/rabbitmq/. "$DATA_ROOT/rabbitmq/" 2>/dev/null || true
    rm -rf /var/lib/rabbitmq; ln -sfn "$DATA_ROOT/rabbitmq" /var/lib/rabbitmq
  fi
  ok "data root ready (existing data preserved)"

  step "3/5  Installing rabbitmq-server + listener/management config"
  if ! command -v rabbitmqctl >/dev/null 2>&1; then apt-get update -y >/dev/null; apt-get install -y rabbitmq-server >/dev/null; fi
  mkdir -p /etc/rabbitmq/conf.d
  cat > /etc/rabbitmq/conf.d/10-dokandar.conf <<CONF
listeners.tcp.1 = ${RABBITMQ_NODE_IP}:${RABBITMQ_AMQP_PORT}
management.tcp.port = ${RABBITMQ_MGMT_PORT}
management.tcp.ip = 0.0.0.0
CONF
  # the data dir + Erlang cookie must be owned by the rabbitmq user, else the broker hits eacces on the
  # cookie and refuses to start (the cookie can land root-owned after the apt postinst + /data symlink).
  chown -R rabbitmq:rabbitmq "$DATA_ROOT/rabbitmq" 2>/dev/null || true
  systemctl reset-failed rabbitmq-server >/dev/null 2>&1 || true   # clear any start-rate-limit from a failed first boot
  systemctl enable rabbitmq-server >/dev/null 2>&1 || true
  systemctl restart rabbitmq-server >/dev/null 2>&1 || systemctl start rabbitmq-server >/dev/null 2>&1 || true
  printf '   waiting for the broker'
  for _ in $(seq 1 30); do rabbitmq-diagnostics -q ping >/dev/null 2>&1 && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  rabbitmq-plugins enable rabbitmq_management >/dev/null 2>&1 || true
  ok "rabbitmq-server $(dpkg-query -W -f='${Version}' rabbitmq-server 2>/dev/null); management plugin on :${RABBITMQ_MGMT_PORT}"

  step "4/5  Admin user '${USER_}' (+ drop guest)"
  rabbitmqctl add_user "$USER_" "$PASS_" >/dev/null 2>&1 || rabbitmqctl change_password "$USER_" "$PASS_" >/dev/null 2>&1 || true
  rabbitmqctl set_user_tags "$USER_" administrator >/dev/null 2>&1 || true
  rabbitmqctl set_permissions -p / "$USER_" ".*" ".*" ".*" >/dev/null 2>&1 || true
  [ "$USER_" != guest ] && rabbitmqctl delete_user guest >/dev/null 2>&1 || true
  rabbitmqctl authenticate_user "$USER_" "$PASS_" >/dev/null 2>&1 && ok "user '${USER_}' authenticates (administrator)" || warn "auth check failed for '${USER_}'"

  step "5/5  Verify"
  rabbitmq-diagnostics -q ping >/dev/null 2>&1 && ok "broker ping OK (svc=$(systemctl is-active rabbitmq-server))" || warn "broker not ready (rabbitmq-diagnostics status)"
  print_summary
}

do_uninstall(){
  step "Stopping RabbitMQ — DATA PRESERVED at ${DATA_ROOT}/rabbitmq"
  systemctl stop rabbitmq-server >/dev/null 2>&1 || true
  [ -L /var/lib/rabbitmq ] && rm -f /var/lib/rabbitmq
  apt-get purge -y rabbitmq-server >/dev/null 2>&1 || true
  apt-get autoremove --purge -y >/dev/null 2>&1 || true
  rm -rf /etc/rabbitmq /var/log/rabbitmq
  ok "RabbitMQ removed. DATA PRESERVED at ${DATA_ROOT}/rabbitmq ($(du -sh "${DATA_ROOT}/rabbitmq" 2>/dev/null | cut -f1 || echo '?'))."
  warn "To remove the data too: sudo bash setup.sh purge"
}
do_purge(){ do_uninstall; step "Purging data dir ${DATA_ROOT}/rabbitmq"; rm -rf "${DATA_ROOT}/rabbitmq" || true; ok "data dir removed — full wipe."; }

do_status(){
  : "${RABBITMQ_MGMT_PORT:=15672}"
  printf 'rabbitmq-server : %s\n' "$(systemctl is-active rabbitmq-server 2>/dev/null)"
  rabbitmq-diagnostics -q ping >/dev/null 2>&1 && echo "ping            : OK" || echo "ping            : DOWN"
  echo "user            : ${RABBITMQ_DEFAULT_USER:-dokandar}   (password in ${ENV_FILE})"
  echo "UI              : http://<host>:${RABBITMQ_MGMT_PORT}"
  echo "data dir        : ${DATA_ROOT}/rabbitmq ($(du -sh "${DATA_ROOT}/rabbitmq" 2>/dev/null | cut -f1 || echo absent))"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  install|do_install)     parse_args "$@"; do_install ;;
  uninstall|do_uninstall) do_uninstall ;;
  purge)                  do_purge ;;
  status)                 do_status ;;
  *) usage; exit 2 ;;
esac
