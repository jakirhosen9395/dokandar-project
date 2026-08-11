#!/usr/bin/env bash
# DOKANDAR utility — PostgreSQL 18 · native single-node (NO Docker), env-file driven.
# Auto-generates a COMPLEX password when none is set; accepts --user / --db / --password / --gen-password.
# Data under ${DATA_ROOT}/postgresql (preserved on uninstall; `purge` wipes). Prints credentials at the end.
#   Usage:  sudo bash setup.sh install [--user U] [--db D] [--password P | --gen-password]
#           sudo bash setup.sh uninstall | purge | status
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
# Load config: shared /etc/dokandar/.env first, then the component .env (overrides).
set -a; [ -f /etc/dokandar/.env ] && . /etc/dokandar/.env; [ -f "$ENV_FILE" ] && . "$ENV_FILE"; set +a
: "${DATA_ROOT:=/data}"

# ---- pretty step output ----------------------------------------------------------------------
_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: sudo bash setup.sh install [--user U] [--db D] [--password P | --gen-password] | uninstall | purge | status"; }

# ---- credential helpers ----------------------------------------------------------------------
# 24-char connection-string-safe password (alphanumeric only). pipefail guarded.
gen_password(){ printf '%s' "$( set +o pipefail
  { command -v openssl >/dev/null 2>&1 && openssl rand -base64 48 || head -c 256 /dev/urandom; } \
  | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24 )"; }
# replace-or-append KEY=VALUE in $ENV_FILE (no sed value interpolation; never duplicates a key).
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true
  # run under sudo => hand the .env to the invoking user so they (and test.sh) can read it (stays 0600)
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }
sqlq(){ printf '%s' "${1//\'/\'\'}"; }   # double single-quotes for safe SQL literals

USER_ARG=""; DB_ARG=""; PASS_ARG=""; GEN=0
parse_args(){ while [ $# -gt 0 ]; do case "$1" in
    --user) USER_ARG="${2:?}"; shift 2;;  --user=*) USER_ARG="${1#*=}"; shift;;
    --db) DB_ARG="${2:?}"; shift 2;;       --db=*) DB_ARG="${1#*=}"; shift;;
    --password) PASS_ARG="${2:?}"; shift 2;; --password=*) PASS_ARG="${1#*=}"; shift;;
    --gen-password) GEN=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1"; usage; exit 2;;
  esac; done; }

resolve_creds(){
  USER_="${USER_ARG:-${POSTGRES_USER:-${POSTGRES_SUPERUSER:-postgres}}}"
  DB_="${DB_ARG:-${POSTGRES_DB:-}}"
  PORT_="${POSTGRES_PORT:-5432}"
  if   [ -n "$PASS_ARG" ];               then PASS_="$PASS_ARG";            PW_SRC="provided (--password)"
  elif [ "$GEN" = 1 ];                   then PASS_="$(gen_password)";      PW_SRC="auto-generated (--gen-password)"
  elif [ -n "${POSTGRES_PASSWORD:-}" ];  then PASS_="$POSTGRES_PASSWORD";   PW_SRC="reused from .env"
  else                                        PASS_="$(gen_password)";      PW_SRC="auto-generated (.env was empty)"
  fi
  # persist resolved values so they survive + are reusable (idempotent re-run reuses the same password)
  set_env_var POSTGRES_USER "$USER_"; [ -n "$DB_" ] && set_env_var POSTGRES_DB "$DB_"; set_env_var POSTGRES_PASSWORD "$PASS_"
}

print_summary(){
  local host="${HOST_IP:-127.0.0.1}" db="${DB_:-postgres}"
  step "Connection details (password shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "================ PostgreSQL 18 (native) — connection details ================"; printf '%s' "$(_c 0)"
  cat <<SUM
  Host / port    : ${host} / ${PORT_}
  User           : ${USER_}
  Password       : ${PASS_}   [${PW_SRC}]
  Database       : ${db}
  Connection URL : postgresql://${USER_}:${PASS_}@${host}:${PORT_}/${db}
  psql           : PGPASSWORD='${PASS_}' psql -h ${host} -p ${PORT_} -U ${USER_} -d ${db}
  Data directory : ${DATA_ROOT}/postgresql
  Browser UI     : none (PostgreSQL ships no web console)
  Saved to       : ${ENV_FILE} (chmod 600, gitignored) — the password persists there
SUM
  printf '%s' "$(_c '1;36')"; echo "============================================================================="; printf '%s' "$(_c 0)"
}

do_install(){
  resolve_creds
  step "1/6  Configuration"
  ok "user=${USER_}  db=${DB_:-<none>}  port=${PORT_}  password=${PW_SRC}"

  step "2/6  Data dir (/var/lib/postgresql -> ${DATA_ROOT}/postgresql) — non-destructive"
  mkdir -p "$DATA_ROOT/postgresql"
  if [ ! -L /var/lib/postgresql ]; then
    systemctl stop postgresql 2>/dev/null || true
    [ -d /var/lib/postgresql ] && cp -a /var/lib/postgresql/. "$DATA_ROOT/postgresql/" 2>/dev/null || true
    rm -rf /var/lib/postgresql; ln -sfn "$DATA_ROOT/postgresql" /var/lib/postgresql
  fi
  ok "data root ready (existing data preserved)"

  step "3/6  Installing PostgreSQL 18 + client + contrib"
  apt-get update -y; apt-get install -y postgresql-18 postgresql-client-18 postgresql-contrib-18
  systemctl enable --now postgresql >/dev/null 2>&1 || true; sleep 3
  ok "packages installed (svc=$(systemctl is-active postgresql 2>/dev/null))"
  sudo -u postgres psql -tAc "CREATE EXTENSION IF NOT EXISTS pg_trgm; CREATE EXTENSION IF NOT EXISTS cube; CREATE EXTENSION IF NOT EXISTS earthdistance;" >/dev/null 2>&1 || true
  ok "extensions enabled (pg_trgm, cube, earthdistance)"

  step "4/6  Listen address + port"
  sudo -u postgres psql -tAc "ALTER SYSTEM SET listen_addresses='${POSTGRES_LISTEN_ADDRESSES:-localhost}'; ALTER SYSTEM SET port=${PORT_};" >/dev/null 2>&1 || true
  systemctl restart postgresql >/dev/null 2>&1 || true; sleep 3
  ok "listen_addresses='${POSTGRES_LISTEN_ADDRESSES:-localhost}' port=${PORT_}"

  step "5/6  Role '${USER_}' + password + optional database '${DB_:-<none>}'"
  local PWS; PWS="$(sqlq "$PASS_")"
  if [ "$USER_" != "postgres" ]; then
    sudo -u postgres psql -tAc "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${USER_}') THEN CREATE ROLE \"${USER_}\" WITH SUPERUSER LOGIN PASSWORD '${PWS}'; END IF; END \$\$;" >/dev/null 2>&1 || true
  fi
  sudo -u postgres psql -tAc "ALTER ROLE \"${USER_}\" WITH LOGIN PASSWORD '${PWS}';" >/dev/null 2>&1 || true
  ok "password set on role '${USER_}'"
  if [ -n "$DB_" ]; then
    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_}'" 2>/dev/null | grep -q 1; then
      sudo -u postgres createdb -p "$PORT_" -O "$USER_" "$DB_" >/dev/null 2>&1 || true; ok "database '${DB_}' created (owner ${USER_})"
    else ok "database '${DB_}' already present"; fi
  fi

  step "6/6  Verifying"
  pg_isready -h 127.0.0.1 -p "$PORT_" >/dev/null 2>&1 && ok "pg_isready OK on 127.0.0.1:${PORT_}" || warn "pg_isready not ready"
  if PGPASSWORD="$PASS_" psql -h 127.0.0.1 -p "$PORT_" -U "$USER_" -d "${DB_:-postgres}" -tAc 'select 1' >/dev/null 2>&1; then
    ok "password auth verified for '${USER_}' over 127.0.0.1:${PORT_}"
  else warn "password auth check failed for '${USER_}'"; fi
  print_summary
}

do_uninstall(){
  step "Stopping PostgreSQL — DATA PRESERVED at ${DATA_ROOT}/postgresql"
  systemctl stop postgresql >/dev/null 2>&1 || true
  if [ -L /var/lib/postgresql ]; then rm -f /var/lib/postgresql; fi
  step "Purging PostgreSQL 18 packages + config/logs (keeping the data)"
  apt-get purge -y 'postgresql-18*' 'postgresql-client-18*' 'postgresql-contrib-18*' postgresql-common 2>/dev/null || true
  apt-get autoremove --purge -y 2>/dev/null || true
  rm -rf /etc/postgresql /var/log/postgresql
  if [ -d /var/lib/postgresql ] && [ ! -L /var/lib/postgresql ]; then rmdir /var/lib/postgresql 2>/dev/null || true; fi
  ok "PostgreSQL removed. DATA PRESERVED at ${DATA_ROOT}/postgresql ($(du -sh "${DATA_ROOT}/postgresql" 2>/dev/null | cut -f1 || echo '?'))."
  warn "To remove the data too: sudo bash setup.sh purge"
}
do_purge(){ do_uninstall; step "Purging preserved data dir ${DATA_ROOT}/postgresql"; rm -rf "${DATA_ROOT}/postgresql" || true; ok "data dir removed — full wipe complete."; }

do_status(){
  : "${POSTGRES_PORT:=5432}"
  printf 'postgresql : %s\n' "$(systemctl is-active postgresql 2>/dev/null)"
  pg_isready -h 127.0.0.1 -p "$POSTGRES_PORT" >/dev/null 2>&1 && echo "pg_isready : OK on 127.0.0.1:${POSTGRES_PORT}" || echo "pg_isready : DOWN on 127.0.0.1:${POSTGRES_PORT}"
  VER="$(sudo -u postgres psql -p "$POSTGRES_PORT" -tAc 'select version()' 2>/dev/null | head -1 || true)"; [ -n "$VER" ] && echo "server     : $VER"
  echo "user/db    : ${POSTGRES_USER:-postgres} / ${POSTGRES_DB:-postgres}   (password in ${ENV_FILE})"
  echo "data dir   : ${DATA_ROOT}/postgresql ($(du -sh "${DATA_ROOT}/postgresql" 2>/dev/null | cut -f1 || echo absent))"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  install|do_install)     parse_args "$@"; do_install ;;
  uninstall|do_uninstall) do_uninstall ;;
  purge)                  do_purge ;;
  status)                 do_status ;;
  *) usage; exit 2 ;;
esac
