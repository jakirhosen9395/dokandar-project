#!/usr/bin/env bash
# DOKANDAR utility — MongoDB 7.0 · native single-node (NO Docker), env-file driven.
# Auto-generates a COMPLEX password when none is set; accepts --user / --db / --password / --gen-password.
# Data under ${DATA_ROOT}/mongodb (preserved on uninstall; `purge` wipes). Prints credentials at the end.
#   Usage:  sudo bash setup.sh install [--user U] [--db D] [--password P | --gen-password]
#           sudo bash setup.sh uninstall | purge | status
#
# WHY 7.0 (not the platform's 8.0/8.3 pin): mongod 8.x SEGFAULT-crashloops on Ubuntu/kernel 7.0 with
# "Linux kernel versions 6.19 and newer has a known incompatibility" (SERVER-121912). 7.0 predates it
# and runs cleanly here — it is the README §9 components-stack pin. Production targets 8.0/8.3 on
# AL2023 hosts where the kernel block does not apply. Override via MONGO_VERSION / MONGO_REPO_CODENAME.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
# Load config: shared /etc/dokandar/.env first, then the component .env (overrides).
set -a; [ -f /etc/dokandar/.env ] && . /etc/dokandar/.env; [ -f "$ENV_FILE" ] && . "$ENV_FILE"; set +a
: "${DATA_ROOT:=/data}"
: "${MONGO_VERSION:=7.0}"
: "${MONGO_REPO_CODENAME:=jammy}"   # MongoDB publishes 7.0 for jammy/focal — NOT noble/resolute (404)

# ---- pretty step output ----------------------------------------------------------------------
_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: sudo bash setup.sh install [--user U] [--db D] [--password P | --gen-password] | uninstall | purge | status"; }

# ---- credential helpers ----------------------------------------------------------------------
gen_password(){ printf '%s' "$( set +o pipefail
  { command -v openssl >/dev/null 2>&1 && openssl rand -base64 48 || head -c 256 /dev/urandom; } \
  | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24 )"; }
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true
  # run under sudo => hand the .env to the invoking user so they (and test.sh) can read it (stays 0600)
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }
# JS string literal escaper (single quotes): wrap a value for mongosh --eval 'db... "VALUE" ...'
jsq(){ printf '%s' "${1//\'/\\\'}"; }

USER_ARG=""; DB_ARG=""; PASS_ARG=""; GEN=0
parse_args(){ while [ $# -gt 0 ]; do case "$1" in
    --user) USER_ARG="${2:?}"; shift 2;;  --user=*) USER_ARG="${1#*=}"; shift;;
    --db) DB_ARG="${2:?}"; shift 2;;       --db=*) DB_ARG="${1#*=}"; shift;;
    --password) PASS_ARG="${2:?}"; shift 2;; --password=*) PASS_ARG="${1#*=}"; shift;;
    --gen-password) GEN=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1"; usage; exit 2;;
  esac; done; }

OLD_PASS=""
resolve_creds(){
  OLD_PASS="${MONGO_ROOT_PASSWORD:-}"   # capture BEFORE overwrite — needed to re-auth for rotation
  USER_="${USER_ARG:-${MONGO_ROOT_USER:-dokandar}}"
  DB_="${DB_ARG:-${MONGO_INITDB_DATABASE:-}}"
  PORT_="${MONGO_PORT:-27017}"
  BIND_="${MONGO_BIND_IP:-0.0.0.0}"     # 0.0.0.0 so a remote client can reach it (auth is required)
  if   [ -n "$PASS_ARG" ];                 then PASS_="$PASS_ARG";            PW_SRC="provided (--password)"
  elif [ "$GEN" = 1 ];                     then PASS_="$(gen_password)";      PW_SRC="auto-generated (--gen-password)"
  elif [ -n "${MONGO_ROOT_PASSWORD:-}" ];  then PASS_="$MONGO_ROOT_PASSWORD"; PW_SRC="reused from .env"
  else                                          PASS_="$(gen_password)";      PW_SRC="auto-generated (.env was empty)"
  fi
  set_env_var MONGO_ROOT_USER "$USER_"
  [ -n "$DB_" ] && set_env_var MONGO_INITDB_DATABASE "$DB_"
  set_env_var MONGO_ROOT_PASSWORD "$PASS_"
  set_env_var MONGO_PORT "$PORT_"
  set_env_var MONGO_BIND_IP "$BIND_"
  set_env_var MONGO_VERSION "$MONGO_VERSION"
}

# run a mongosh eval with explicit auth (root@admin); echoes the eval's printed output
msh_auth(){ local pw="$1" js="$2"
  mongosh --quiet --host 127.0.0.1 --port "$PORT_" -u "$USER_" -p "$pw" --authenticationDatabase admin --eval "$js" 2>/dev/null; }
# run a mongosh eval with NO credentials (used under the localhost exception before the first user)
msh_noauth(){ mongosh --quiet --host 127.0.0.1 --port "$PORT_" --eval "$1" 2>/dev/null; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}" db="${DB_:-test}"
  [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (password shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "================ MongoDB ${MONGO_VERSION} (native) — connection details ================"; printf '%s' "$(_c 0)"
  cat <<SUM
  Host / port    : ${host} / ${PORT_}   (binds ${BIND_})
  User           : ${USER_}   (built-in role: root @ admin)
  Password       : ${PASS_}   [${PW_SRC}]
  Auth database  : admin
  Database       : ${db}
  Connection URI : mongodb://${USER_}:${PASS_}@${host}:${PORT_}/?authSource=admin
  mongosh        : mongosh "mongodb://${USER_}:${PASS_}@${host}:${PORT_}/?authSource=admin"
  Test from afar : bash ../test.sh "mongodb://${USER_}:${PASS_}@${host}:${PORT_}/?authSource=admin"
  Data directory : ${DATA_ROOT}/mongodb
  Browser UI     : none (MongoDB ships no web console; mongo-express is a Docker-only companion)
  Saved to       : ${ENV_FILE} (chmod 600, gitignored) — the password persists there
SUM
  printf '%s' "$(_c '1;36')"; echo "==========================================================================="; printf '%s' "$(_c 0)"
}

do_install(){
  resolve_creds
  step "1/6  Configuration"
  ok "user=${USER_}  db=${DB_:-<none>}  port=${PORT_}  bindIp=${BIND_}  version=${MONGO_VERSION}  password=${PW_SRC}"

  step "2/6  Data dir (/var/lib/mongodb -> ${DATA_ROOT}/mongodb) — non-destructive"
  mkdir -p "$DATA_ROOT/mongodb"
  if [ ! -L /var/lib/mongodb ]; then
    systemctl stop mongod 2>/dev/null || true
    [ -d /var/lib/mongodb ] && cp -a /var/lib/mongodb/. "$DATA_ROOT/mongodb/" 2>/dev/null || true
    rm -rf /var/lib/mongodb; ln -sfn "$DATA_ROOT/mongodb" /var/lib/mongodb
  fi
  ok "data root ready (existing data preserved)"

  step "3/6  Installing MongoDB ${MONGO_VERSION} (apt repo: ${MONGO_REPO_CODENAME}) + mongosh"
  if ! command -v mongod >/dev/null 2>&1; then
    apt-get update -y >/dev/null
    apt-get install -y wget gnupg curl ca-certificates >/dev/null
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL "https://www.mongodb.org/static/pgp/server-${MONGO_VERSION}.asc" \
      | gpg --batch --yes --dearmor -o "/etc/apt/keyrings/mongodb-${MONGO_VERSION}.gpg"
    echo "deb [signed-by=/etc/apt/keyrings/mongodb-${MONGO_VERSION}.gpg] https://repo.mongodb.org/apt/ubuntu ${MONGO_REPO_CODENAME}/mongodb-org/${MONGO_VERSION} multiverse" \
      > "/etc/apt/sources.list.d/mongodb-org-${MONGO_VERSION}.list"
    apt-get update -y >/dev/null
    apt-get install -y mongodb-org >/dev/null
  fi
  ok "$(mongod --version | head -1)"

  step "4/6  net config (port=${PORT_}, bootstrap on LOOPBACK) + first start (auth OFF)"
  chown -R mongodb:mongodb "$DATA_ROOT/mongodb" /var/log/mongodb 2>/dev/null || true
  if [ -f /etc/mongod.conf ]; then
    sed -i "s/^\(\s*\)port:.*/\1port: ${PORT_}/" /etc/mongod.conf || true
    # bootstrap bound to 127.0.0.1 ONLY: createUser runs over the localhost exception, so the brief
    # auth-OFF window is never exposed on the network. bindIp is widened to ${BIND_} in step 6.
    sed -i "s/^\(\s*\)bindIp:.*/\1bindIp: 127.0.0.1/" /etc/mongod.conf || true
    sed -i "s/^\(\s*\)authorization:.*/\1authorization: disabled/" /etc/mongod.conf 2>/dev/null || true
  fi
  systemctl enable --now mongod >/dev/null 2>&1 || true
  # wait for it to accept connections
  for _ in $(seq 1 20); do [ "$(msh_noauth 'db.runCommand({ping:1}).ok' 2>/dev/null)" = 1 ] && break; sleep 1; done
  ok "mongod svc=$(systemctl is-active mongod 2>/dev/null) on 127.0.0.1:${PORT_} (bootstrap)"

  step "5/6  Root user '${USER_}' + optional database '${DB_:-<none>}'"
  local PWS; PWS="$(jsq "$PASS_")"
  if [ "$(msh_auth "$PASS_" 'db.runCommand({ping:1}).ok')" = 1 ]; then
    ok "auth already enabled; '${USER_}' authenticates with the current password (idempotent)"
  elif [ -n "$OLD_PASS" ] && [ "$(msh_auth "$OLD_PASS" 'db.runCommand({ping:1}).ok')" = 1 ]; then
    msh_auth "$OLD_PASS" "db.getSiblingDB('admin').updateUser('$(jsq "$USER_")',{pwd:'${PWS}'})" >/dev/null 2>&1 || true
    ok "rotated password for existing user '${USER_}'"
  else
    # fresh: create the root user under the localhost exception (auth still off)
    msh_noauth "db.getSiblingDB('admin').createUser({user:'$(jsq "$USER_")',pwd:'${PWS}',roles:[{role:'root',db:'admin'}]})" >/dev/null 2>&1 \
      && ok "created root user '${USER_}'" || warn "could not create user '${USER_}' (see: journalctl -u mongod)"
  fi
  if [ -n "$DB_" ]; then
    msh_noauth "db.getSiblingDB('$(jsq "$DB_")').createCollection('_init')" >/dev/null 2>&1 \
      || msh_auth "$PASS_" "db.getSiblingDB('$(jsq "$DB_")').createCollection('_init')" >/dev/null 2>&1 || true
    ok "database '${DB_}' initialized"
  fi

  step "6/6  Enabling authorization + widening bindIp to ${BIND_} + verifying"
  if grep -qE '^\s*authorization:' /etc/mongod.conf 2>/dev/null; then
    sed -i "s/^\(\s*\)authorization:.*/\1authorization: enabled/" /etc/mongod.conf
  else
    printf '\nsecurity:\n  authorization: enabled\n' >> /etc/mongod.conf
  fi
  # NOW (and only now, with auth ON) widen the listener to the configured bindIp.
  sed -i "s/^\(\s*\)bindIp:.*/\1bindIp: ${BIND_}/" /etc/mongod.conf || true
  systemctl restart mongod >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do [ "$(msh_auth "$PASS_" 'db.runCommand({ping:1}).ok')" = 1 ] && break; sleep 1; done
  if [ "$(msh_auth "$PASS_" 'db.runCommand({ping:1}).ok')" = 1 ]; then
    ok "auth=on  user='${USER_}'  ping=ok on ${BIND_}:${PORT_}"
  else warn "auth verify failed for '${USER_}' (warming up? check: systemctl status mongod)"; fi
  print_summary
}

do_uninstall(){
  step "Stopping mongod — DATA PRESERVED at ${DATA_ROOT}/mongodb"
  systemctl stop mongod >/dev/null 2>&1 || true
  [ -L /var/lib/mongodb ] && rm -f /var/lib/mongodb
  step "Purging mongodb-org packages + repo/config/logs (keeping the data)"
  apt-get purge -y 'mongodb-org*' >/dev/null 2>&1 || true
  apt-get autoremove --purge -y >/dev/null 2>&1 || true
  rm -rf /var/log/mongodb /etc/mongod.conf
  rm -f "/etc/apt/sources.list.d/mongodb-org-${MONGO_VERSION}.list" "/etc/apt/keyrings/mongodb-${MONGO_VERSION}.gpg"
  apt-get update -y >/dev/null 2>&1 || true
  ok "MongoDB removed. DATA PRESERVED at ${DATA_ROOT}/mongodb ($(du -sh "${DATA_ROOT}/mongodb" 2>/dev/null | cut -f1 || echo '?'))."
  warn "To remove the data too: sudo bash setup.sh purge"
}
do_purge(){ do_uninstall; step "Purging preserved data dir ${DATA_ROOT}/mongodb"; rm -rf "${DATA_ROOT}/mongodb" || true; ok "data dir removed — full wipe complete."; }

do_status(){
  : "${MONGO_PORT:=27017}"; : "${MONGO_ROOT_USER:=dokandar}"; : "${MONGO_ROOT_PASSWORD:=}"
  printf 'mongod     : %s\n' "$(systemctl is-active mongod 2>/dev/null)"
  local PING
  if [ -n "$MONGO_ROOT_PASSWORD" ]; then
    PING="$(mongosh --quiet --port "$MONGO_PORT" -u "$MONGO_ROOT_USER" -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin --eval 'db.runCommand({ping:1}).ok' 2>/dev/null || echo 0)"
  else PING="$(mongosh --quiet --port "$MONGO_PORT" --eval 'db.runCommand({ping:1}).ok' 2>/dev/null || echo 0)"; fi
  [ "$PING" = 1 ] && echo "ping       : OK on :${MONGO_PORT}" || echo "ping       : DOWN on :${MONGO_PORT}"
  VER="$(mongod --version 2>/dev/null | head -1)"; [ -n "$VER" ] && echo "server     : $VER"
  echo "user       : ${MONGO_ROOT_USER} @ admin   (password in ${ENV_FILE})"
  echo "data dir   : ${DATA_ROOT}/mongodb ($(du -sh "${DATA_ROOT}/mongodb" 2>/dev/null | cut -f1 || echo absent))"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  install|do_install)     parse_args "$@"; do_install ;;
  uninstall|do_uninstall) do_uninstall ;;
  purge)                  do_purge ;;
  status)                 do_status ;;
  *) usage; exit 2 ;;
esac
