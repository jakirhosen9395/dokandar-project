#!/usr/bin/env bash
# DOKANDAR utility — Redis 8 · native single-node (NO Docker), env-file driven.
# Auth ON via requirepass; auto-generates a COMPLEX password when none is set; --gen-password rotates.
# Data under ${DATA_ROOT}/redis (AOF persistence; preserved on uninstall; `purge` wipes). Prints creds.
#   Usage:  sudo bash setup.sh install [--password P | --gen-password] | uninstall | purge | status
#   (Redis has a single `default` ACL user + numbered DBs, so --user/--db do not apply.)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
set -a; [ -f /etc/dokandar/.env ] && . /etc/dokandar/.env; [ -f "$ENV_FILE" ] && . "$ENV_FILE"; set +a
: "${DATA_ROOT:=/data}"
: "${REDIS_PORT:=6379}"; : "${REDIS_BIND:=0.0.0.0}"; : "${REDIS_MAXMEMORY:=256mb}"
CONF=/etc/redis/redis.conf

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
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1"; usage; exit 2;;
  esac; done; }

resolve_creds(){
  if   [ -n "$PASS_ARG" ];               then PASS_="$PASS_ARG";            PW_SRC="provided (--password)"
  elif [ "$GEN" = 1 ];                   then PASS_="$(gen_password)";      PW_SRC="auto-generated (--gen-password)"
  elif [ -n "${REDIS_PASSWORD:-}" ];     then PASS_="$REDIS_PASSWORD";      PW_SRC="reused from .env"
  else                                        PASS_="$(gen_password)";      PW_SRC="auto-generated (.env was empty)"
  fi
  set_env_var REDIS_PASSWORD "$PASS_"; set_env_var REDIS_PORT "$REDIS_PORT"; set_env_var REDIS_BIND "$REDIS_BIND"
}

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (password shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "================ Redis 8 (native) — connection details ================"; printf '%s' "$(_c 0)"
  cat <<SUM
  Endpoint       : ${host}:${REDIS_PORT}   (binds ${REDIS_BIND})
  Auth           : requirepass (ACL 'default' user; no username)
  Password       : ${PASS_}   [${PW_SRC}]
  Connection URL : redis://default:${PASS_}@${host}:${REDIS_PORT}/0
  redis-cli      : redis-cli -h ${host} -p ${REDIS_PORT} -a '${PASS_}' ping     # -> PONG
  Test from afar : bash ../test.sh "redis://default:${PASS_}@${host}:${REDIS_PORT}"
  Data directory : ${DATA_ROOT}/redis   (appendonly AOF)
  Browser UI     : none (Redis has no web console; use redis-cli / RedisInsight)
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "======================================================================="; printf '%s' "$(_c 0)"
}

do_install(){
  resolve_creds
  step "1/5  Configuration"
  ok "port=${REDIS_PORT} bind=${REDIS_BIND} auth=on maxmemory=${REDIS_MAXMEMORY} password=${PW_SRC}"

  step "2/5  Data dir (/var/lib/redis -> ${DATA_ROOT}/redis) — non-destructive"
  mkdir -p "$DATA_ROOT/redis"
  if [ ! -L /var/lib/redis ]; then
    systemctl stop redis-server 2>/dev/null || true
    [ -d /var/lib/redis ] && cp -a /var/lib/redis/. "$DATA_ROOT/redis/" 2>/dev/null || true
    rm -rf /var/lib/redis; ln -sfn "$DATA_ROOT/redis" /var/lib/redis
  fi
  ok "data root ready (existing data preserved)"

  step "3/5  Installing redis-server"
  if ! command -v redis-server >/dev/null 2>&1; then apt-get update -y >/dev/null; apt-get install -y redis-server >/dev/null; fi
  ok "$(redis-server --version | cut -d' ' -f1-3)"

  step "4/5  Managed config (bind ${REDIS_BIND}, requirepass, AOF, maxmemory)"
  chown -R redis:redis "$DATA_ROOT/redis" 2>/dev/null || true
  # strip a prior managed block, then append ours (last directive wins in redis.conf)
  sed -i '/^# >>> dokandar managed >>>/,/^# <<< dokandar managed <<</d' "$CONF" 2>/dev/null || true
  {
    echo "# >>> dokandar managed >>>"
    echo "bind ${REDIS_BIND}"
    echo "port ${REDIS_PORT}"
    echo "protected-mode yes"
    echo "requirepass ${PASS_}"
    echo "dir ${DATA_ROOT}/redis"
    echo "appendonly yes"
    echo "maxmemory ${REDIS_MAXMEMORY}"
    echo "maxmemory-policy allkeys-lru"
    echo "# <<< dokandar managed <<<"
  } >> "$CONF"
  ok "managed block written to ${CONF}"

  step "5/5  Restart + verify"
  systemctl enable redis-server >/dev/null 2>&1 || true
  systemctl restart redis-server >/dev/null 2>&1 || true; sleep 2
  local PONG; PONG="$(redis-cli -h 127.0.0.1 -p "$REDIS_PORT" -a "$PASS_" ping 2>/dev/null)"
  [ "$PONG" = PONG ] && ok "auth OK — PING -> PONG on 127.0.0.1:${REDIS_PORT}" || warn "PING failed (warming up? systemctl status redis-server)"
  print_summary
}

do_uninstall(){
  step "Stopping redis-server — DATA PRESERVED at ${DATA_ROOT}/redis"
  systemctl stop redis-server >/dev/null 2>&1 || true
  [ -L /var/lib/redis ] && rm -f /var/lib/redis
  apt-get purge -y redis-server redis-tools >/dev/null 2>&1 || true
  apt-get autoremove --purge -y >/dev/null 2>&1 || true
  rm -rf /etc/redis /var/log/redis
  ok "Redis removed. DATA PRESERVED at ${DATA_ROOT}/redis ($(du -sh "${DATA_ROOT}/redis" 2>/dev/null | cut -f1 || echo '?'))."
  warn "To remove the data too: sudo bash setup.sh purge"
}
do_purge(){ do_uninstall; step "Purging data dir ${DATA_ROOT}/redis"; rm -rf "${DATA_ROOT}/redis" || true; ok "data dir removed — full wipe."; }

do_status(){
  : "${REDIS_PORT:=6379}"; : "${REDIS_PASSWORD:=}"
  printf 'redis-server : %s\n' "$(systemctl is-active redis-server 2>/dev/null)"
  local PONG; PONG="$(redis-cli -h 127.0.0.1 -p "$REDIS_PORT" ${REDIS_PASSWORD:+-a "$REDIS_PASSWORD"} ping 2>/dev/null)"
  [ "$PONG" = PONG ] && echo "ping         : PONG on :${REDIS_PORT}" || echo "ping         : DOWN on :${REDIS_PORT}"
  echo "data dir     : ${DATA_ROOT}/redis ($(du -sh "${DATA_ROOT}/redis" 2>/dev/null | cut -f1 || echo absent))"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  install|do_install)     parse_args "$@"; do_install ;;
  uninstall|do_uninstall) do_uninstall ;;
  purge)                  do_purge ;;
  status)                 do_status ;;
  *) usage; exit 2 ;;
esac
