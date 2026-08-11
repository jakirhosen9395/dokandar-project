#!/usr/bin/env bash
# DOKANDAR utility — PostgreSQL 18 · Docker Compose HA cluster · lifecycle wrapper.
# Auto-generates COMPLEX superuser + replication passwords when unset; accepts --user/--db/--password.
# Per-node data are HOST bind mounts under ${DATA_ROOT}/postgresql_cluster/ and SURVIVE `down -v`.
# Prints credentials at the end. The replication password is baked into the replicas at clone time, so
# it is generated ONCE (first up) and NEVER rotated here; --gen-password rotates only the superuser.
#   Usage:  bash setup.sh up [--user U] [--db D] [--password P | --gen-password]
#           bash setup.sh down | purge | status | acceptance | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || { echo "No .env here — run:  cp .env.example .env"; exit 2; }
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; CDIR="${DATA_ROOT}/postgresql_cluster"
PP="${POSTGRES_PORT:-5432}"; R1="${PG_REPLICA1_PORT:-5433}"; R2="${PG_REPLICA2_PORT:-5434}"

# ---- pretty step output ----
_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up [--user U] [--db D] [--password P | --gen-password] | down | purge | status | acceptance | logs"; }

gen_password(){ printf '%s' "$( set +o pipefail
  { command -v openssl >/dev/null 2>&1 && openssl rand -base64 48 || head -c 256 /dev/urandom; } \
  | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24 )"; }
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }
sqlq(){ printf '%s' "${1//\'/\'\'}"; }

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
  local OLD_USER="${POSTGRES_USER:-postgres}"
  if [ -n "$USER_ARG" ] && [ "$USER_ARG" != "$OLD_USER" ] && sudo test -d "${CDIR}/primary/pgdata" 2>/dev/null; then
    warn "existing cluster superuser is '${OLD_USER}' — Docker cannot rename it; ignoring --user '${USER_ARG}'"; USER_ARG=""
  fi
  USER_="${USER_ARG:-$OLD_USER}"; DB_="${DB_ARG:-${POSTGRES_DB:-}}"
  if   [ -n "$PASS_ARG" ];              then PASS_="$PASS_ARG";          PW_SRC="provided (--password)"
  elif [ "$GEN" = 1 ];                  then PASS_="$(gen_password)";    PW_SRC="auto-generated (--gen-password)"
  elif [ -n "${POSTGRES_PASSWORD:-}" ]; then PASS_="$POSTGRES_PASSWORD"; PW_SRC="reused from .env"
  else                                       PASS_="$(gen_password)";    PW_SRC="auto-generated (.env was empty)"
  fi
  : "${REPL_USER:=replicator}"
  # Replication password is baked into the replicas at clone — generate ONLY if empty, never rotate.
  if [ -z "${REPL_PASSWORD:-}" ]; then REPL_PASSWORD="$(gen_password)"; REPL_SRC="auto-generated"; set_env_var REPL_PASSWORD "$REPL_PASSWORD"
  else REPL_SRC="reused from .env"; fi
  set_env_var POSTGRES_USER "$USER_"; [ -n "$DB_" ] && set_env_var POSTGRES_DB "$DB_"; set_env_var POSTGRES_PASSWORD "$PASS_"
  set_env_var REPL_USER "$REPL_USER"
}

wait_healthy(){ local c; for c in dokandar_pg_primary dokandar_pg_replica1 dokandar_pg_replica2; do
  printf '   %-22s' "$c"
  for _ in $(seq 1 75); do [ "$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo)" = healthy ] && { echo healthy; break; }; printf '.'; sleep 2; done
done; }

print_summary(){
  local db="${DB_:-postgres}"
  step "Connection details (passwords shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "========= PostgreSQL 18 HA cluster (Docker) — connection details ========="; printf '%s' "$(_c 0)"
  cat <<SUM
  Primary (RW)   : 127.0.0.1:${PP}    user=${USER_}  db=${db}      <- writes here
  Replica 1 (RO) : 127.0.0.1:${R1}    (read-only hot standby)
  Replica 2 (RO) : 127.0.0.1:${R2}    (read-only hot standby)
  Superuser pass : ${PASS_}   [${PW_SRC}]
  Repl role/pass : ${REPL_USER}/${REPL_PASSWORD}   [${REPL_SRC}]  (slots replica1_slot/replica2_slot)
  Write URL      : postgresql://${USER_}:${PASS_}@127.0.0.1:${PP}/${db}
  Read URL       : postgresql://${USER_}:${PASS_}@127.0.0.1:${R1}/${db}   (or :${R2})
  psql (RW)      : PGPASSWORD='${PASS_}' psql -h 127.0.0.1 -p ${PP} -U ${USER_} -d ${db}
  Verify HA      : bash setup.sh acceptance
  Data (host)    : ${CDIR}/{primary,replica1,replica2}   (bind mounts — survive 'down -v')
  Browser UI     : none
  Saved to       : ${ENV_FILE} (chmod 600, gitignored) — passwords persist there
SUM
  printf '%s' "$(_c '1;36')"; echo "=========================================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  resolve_creds
  step "1/5  Configuration"; ok "user=${USER_}  db=${DB_:-<none>}  ports=${PP}/${R1}/${R2}  superuser-pw=${PW_SRC}  repl-pw=${REPL_SRC}"
  step "2/5  Bind-mount data dirs"; sudo mkdir -p "$CDIR/primary" "$CDIR/replica1" "$CDIR/replica2"; ok "$CDIR/{primary,replica1,replica2}"
  step "3/5  docker compose up (primary first, then replicas clone + stream)"; docker compose up -d --build
  step "4/5  Waiting for all 3 nodes healthy"; wait_healthy
  step "5/5  Enforcing superuser password + optional database (on the PRIMARY; replicates)"
  local PWS; PWS="$(sqlq "$PASS_")"
  if docker compose exec -T pg-primary psql -v ON_ERROR_STOP=1 -U "$USER_" -d postgres -c "ALTER ROLE \"${USER_}\" WITH LOGIN PASSWORD '${PWS}';" >/dev/null 2>&1; then
    ok "superuser password set on the primary (replicates to standbys)"
  else warn "could not ALTER ROLE '${USER_}' on the primary — see 'bash setup.sh logs'"; fi
  if [ -n "$DB_" ]; then
    if docker compose exec -T pg-primary psql -U "$USER_" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_}'" 2>/dev/null | grep -q 1; then ok "database '${DB_}' already present"
    else docker compose exec -T pg-primary createdb -U "$USER_" -O "$USER_" "$DB_" >/dev/null 2>&1 && ok "database '${DB_}' created (replicates)" || warn "could not create db '${DB_}'"; fi
  fi
  docker compose ps
  print_summary
}

do_acceptance(){
  export PGPASSWORD="${POSTGRES_PASSWORD:-}"; local U="${POSTGRES_USER:-postgres}" DB="${POSTGRES_DB:-postgres}"
  # dual-mode psql: host client if present, else a postgres:N Docker container (--network host) — so the
  # read/write-split verification needs NO host packages and exercises the PUBLISHED RW/RO ports.
  if command -v psql >/dev/null 2>&1; then PSQL(){ psql "$@"; }
  else PSQL(){ docker run --rm --network host -e PGPASSWORD="$PGPASSWORD" "postgres:${POSTGRES_VERSION:-18}" psql "$@"; }; fi
  q(){ PSQL -h 127.0.0.1 -p "$1" -U "$U" -d "$DB" -tAqc "$2"; }
  local fail=0 n s want got
  echo "== PostgreSQL HA acceptance (the run_book's 5 criteria) =="
  n=$(q "$PP" "SELECT count(*) FROM pg_stat_replication WHERE state='streaming'" 2>/dev/null || echo X)
  [ "$n" = 2 ] && echo "  ✓ 1. primary shows 2 streaming standbys" || { echo "  ✗ 1. streaming standbys=$n (want 2)"; fail=1; }
  s=$(q "$PP" "SELECT count(*) FROM pg_replication_slots WHERE active" 2>/dev/null || echo X)
  [ "$s" = 2 ] && echo "  ✓ 4. 2 active replication slots" || { echo "  ✗ 4. active slots=$s (want 2)"; fail=1; }
  q "$PP" "CREATE TABLE IF NOT EXISTS ha_check(id serial primary key, note text, at timestamptz default now()); INSERT INTO ha_check(note) VALUES('accept '||now());" >/dev/null
  sleep 1; want=$(q "$PP" "SELECT count(*) FROM ha_check")
  for rp in "$R1" "$R2"; do
    got=$(q "$rp" "SELECT count(*) FROM ha_check" 2>/dev/null || echo X)
    [ "$got" = "$want" ] && echo "  ✓ 2. replica :$rp has the replicated row (count=$got)" || { echo "  ✗ 2. replica :$rp count=$got (want $want)"; fail=1; }
    if q "$rp" "INSERT INTO ha_check(note) VALUES('should fail')" >/dev/null 2>&1; then echo "  ✗ 3. replica :$rp ACCEPTED a write"; fail=1; else echo "  ✓ 3. replica :$rp is read-only"; fi
  done
  q "$PP" "DROP TABLE IF EXISTS ha_check" >/dev/null
  echo "  5. failover (pg_promote) — see README 'Failover'."
  [ "$fail" = 0 ] && echo "ACCEPTANCE: PASS" || { echo "ACCEPTANCE: FAIL"; exit 1; }
}

do_status(){
  docker compose ps || true
  if command -v psql >/dev/null 2>&1; then export PGPASSWORD="${POSTGRES_PASSWORD:-}"; local U="${POSTGRES_USER:-postgres}"
    echo "primary streaming standbys: $(psql -h 127.0.0.1 -p "$PP" -U "$U" -d postgres -tAqc "SELECT count(*) FROM pg_stat_replication WHERE state='streaming'" 2>/dev/null || echo '?')"
    for rp in "$R1" "$R2"; do echo "replica :$rp in_recovery: $(psql -h 127.0.0.1 -p "$rp" -U "$U" -d postgres -tAqc 'SELECT pg_is_in_recovery()' 2>/dev/null || echo '?')"; done
  fi
  echo "user/db    : ${POSTGRES_USER:-postgres} / ${POSTGRES_DB:-postgres}   (passwords in ${ENV_FILE})"
  echo "data (host): ${CDIR} ($(sudo du -sh "$CDIR" 2>/dev/null | cut -f1 || echo absent))"
}

do_down(){ docker compose down; echo "Cluster stopped. DATA PRESERVED at ${CDIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$CDIR"; echo "Full wipe: containers + ${CDIR} removed."; }

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  up|install)     parse_args "$@"; do_up ;;
  down|uninstall) do_down ;;
  purge)          do_purge ;;
  status)         do_status ;;
  acceptance)     do_acceptance ;;
  logs)           docker compose logs --tail=100 -f ;;
  *) usage; exit 2 ;;
esac
