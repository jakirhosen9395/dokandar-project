#!/usr/bin/env bash
# DOKANDAR — PostgreSQL contract/smoke test. Tests ANY PostgreSQL server/instance.
# It creates a THROWAWAY database `dokandar_pgtest_<ts>` (+ a throwaway role) on the target server,
# exercises DDL/DML, constraints, transactions and the DOKANDAR extensions, prints a PASS/FAIL report,
# then DROPS every test object (trap-guarded) and PROVES zero residue. It never touches a pre-existing
# database (it connects to the `postgres` maintenance DB only to create/drop its own throwaway one).
#
#   Usage:  bash test.sh [TARGET]
#     TARGET may be any ONE of:
#       • a connection string (URI):  bash test.sh "postgresql://user:pass@host:5432/db"
#       • an install-variant folder:  bash test.sh 03_docker_single   (reads that variant's .env)
#       • an explicit env-file path:  bash test.sh ./03_docker_single/.env
#       • omitted: see the resolution order below.
#     Connection sources (highest priority first):
#       1. explicit libpq env:   PGHOST=… PGPORT=… PGUSER=… PGPASSWORD=…  bash test.sh
#       2. a connection string:  the TARGET arg, or   DATABASE_URL='postgresql://…'  bash test.sh
#       3. a `.env` BESIDE this script (01_PostgreSQL/.env) holding DATABASE_URL= or PG*/POSTGRES_* vars
#       4. a per-variant .env:   the TARGET folder, or the first NN_*/.env found
#       5. defaults:             127.0.0.1:5432  user=postgres
#     The connection's dbname (if any) is ignored — the test makes its own throwaway DB; the user needs
#     CREATEDB (or superuser) rights and access to the `postgres` database.
#
# NOTE: intentionally NOT `set -e` — each test handles its own exit code (we deliberately run queries
# that are EXPECTED to fail, e.g. constraint violations). `set -uo pipefail` keeps the rest strict.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# ---- connection resolution: connection string | variant .env | this-dir .env | libpq env -----
# Save explicitly-set libpq vars so they always win over any file/URL.
_H="${PGHOST:-}"; _P="${PGPORT:-}"; _U="${PGUSER:-}"; _W="${PGPASSWORD:-}"

urldecode(){ local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }
# Decompose a postgres[ql]:// URI into PGHOST/PGPORT/PGUSER/PGPASSWORD (dbname/params ignored — the test
# makes its own database). Standard form: postgresql://user:pass@host:port/db?params
parse_pg_url(){
  local u="$1" creds host
  u="${u#postgresql://}"; u="${u#postgres://}"; u="${u%%\?*}"
  if [ "${u#*@}" != "$u" ]; then creds="${u%@*}"; host="${u##*@}"; else creds=""; host="$u"; fi
  host="${host%%/*}"
  if [ -n "$creds" ]; then
    if [ "${creds#*:}" != "$creds" ]; then PGUSER="$(urldecode "${creds%%:*}")"; PGPASSWORD="$(urldecode "${creds#*:}")"
    else PGUSER="$(urldecode "$creds")"; fi
  fi
  if [ "${host#*:}" != "$host" ]; then PGHOST="${host%%:*}"; PGPORT="${host#*:}"; elif [ -n "$host" ]; then PGHOST="$host"; fi
}

ARG="${1:-}"; CONNURL=""; ENVF=""
case "$ARG" in
  postgres://*|postgresql://*) CONNURL="$ARG" ;;            # TARGET is a connection string
  "")        : ;;                                           # no arg → resolve below
  *.env|*/*) ENVF="$ARG" ;;                                 # explicit env-file path
  *)         ENVF="$HERE/$ARG/.env" ;;                      # a variant folder name
esac
[ -z "$CONNURL" ] && [ -n "${DATABASE_URL:-}" ] && CONNURL="$DATABASE_URL"

# Source an env file when no connection string was given: the named variant, else this folder's own
# .env (may hold DATABASE_URL or PG*/POSTGRES_*), else the first per-variant .env.
if [ -z "$CONNURL" ]; then
  if [ -n "$ENVF" ]; then
    if   [ -r "$ENVF" ]; then set -a; . "$ENVF"; set +a
    elif [ -f "$ENVF" ]; then echo "  ! env file exists but is NOT READABLE: $ENVF — run as its owner, or: sudo chown \$(id -un): \"$ENVF\"" >&2
    else echo "  ! env file not found: $ENVF (using PG* env / defaults)" >&2; fi
  elif [ -r "$HERE/.env" ]; then
    set -a; . "$HERE/.env"; set +a
  else
    for f in "$HERE"/0*_*/.env /etc/dokandar/.env; do [ -r "$f" ] || continue; set -a; . "$f"; set +a; break; done
  fi
  [ -n "${DATABASE_URL:-}" ] && CONNURL="$DATABASE_URL"     # a sourced .env may define DATABASE_URL
fi

# Decompose a connection string (if any) into PG*.
if [ -n "$CONNURL" ]; then
  case "$CONNURL" in postgres://*|postgresql://*) parse_pg_url "$CONNURL" ;;
    *) echo "  ! unsupported connection string (use postgresql://user:pass@host:port/db): $CONNURL" >&2 ;; esac
fi

# Explicit libpq env wins, then the connection-string/.env-derived values, then POSTGRES_*, then defaults.
# Native uses POSTGRES_SUPERUSER; the docker image uses POSTGRES_USER — accept either.
export PGHOST="${_H:-${PGHOST:-127.0.0.1}}"
export PGPORT="${_P:-${PGPORT:-${POSTGRES_PORT:-5432}}}"
export PGUSER="${_U:-${PGUSER:-${POSTGRES_SUPERUSER:-${POSTGRES_USER:-postgres}}}}"
PGPASSWORD="${_W:-${PGPASSWORD:-${POSTGRES_PASSWORD:-}}}"; [ -n "$PGPASSWORD" ] && export PGPASSWORD

# ---- choose HOW to run psql: a host client, or (when none is installed) a Docker fallback ------
# A Docker variant publishes its port but installs NO host psql. Rather than fail with a misleading
# "no server", run psql in Docker:
#   host mode   : psql/pg_isready on PATH        -> connect over TCP to PGHOST:PGPORT (preferred).
#   docker mode : no host client, but a LOCAL container publishes PGPORT ->
#                   - bulk DDL/DML go through `docker exec` (container socket, trust: fast, no pw);
#                   - the connectivity gate + TCP/scram auth go through `docker run --network host`
#                     so a PASS proves the PUBLISHED port PGHOST:PGPORT really works (Linux host net).
is_local_host(){ case "$1" in 127.0.0.1|localhost|::1|0.0.0.0) return 0;; esac
  local ip; for ip in $(hostname -I 2>/dev/null); do [ "$1" = "$ip" ] && return 0; done; return 1; }

RUNMODE=""; CON=""; PG_IMAGE=""
if command -v psql >/dev/null 2>&1 && command -v pg_isready >/dev/null 2>&1; then
  RUNMODE=host
elif command -v docker >/dev/null 2>&1 && is_local_host "$PGHOST"; then
  CON="$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | awk -F'\t' -v p=":${PGPORT}->" 'index($2,p){print $1; exit}')"
  if [ -n "$CON" ]; then
    PG_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$CON" 2>/dev/null)"; : "${PG_IMAGE:=postgres:${POSTGRES_VERSION:-18}}"
    RUNMODE=docker
  fi
fi
if [ -z "$RUNMODE" ]; then
  v="${POSTGRES_VERSION:-18}"
  {
    printf '  \033[31m✗\033[0m no PostgreSQL client (psql/pg_isready) on this host, and no local container serves %s:%s\n' "$PGHOST" "$PGPORT"
    printf '     Fix ONE of:\n'
    printf '       • install a host client:  sudo apt-get install -y postgresql-client-%s   (psql + pg_isready)\n' "$v"
    printf '       • for a Docker variant, start it first:  bash <NN_variant>/setup.sh up   (then re-run from here)\n'
    printf '       • point at a server reachable from a host that HAS psql.\n'
  } >&2
  echo "RESULT: FAIL (no psql client)"; exit 2
fi

# psql / pg_isready / TCP-auth runners — implementation swapped by mode (everything else is identical).
if [ "$RUNMODE" = docker ]; then
  PSQL()    { docker exec -e PGCLIENTENCODING=UTF8 -i "$CON" psql -U "$PGUSER" "$@"; }                       # container socket (trust)
  PGREADY() { docker run --rm --network host --entrypoint pg_isready "$PG_IMAGE" -h "$PGHOST" -p "$PGPORT" >/dev/null 2>&1; }
  AUTH_TCP(){ docker run --rm --network host -e PGPASSWORD="${PGPASSWORD:-}" --entrypoint psql "$PG_IMAGE" \
                -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$1" -tAqc "SELECT 1" >/dev/null 2>&1; }
else
  PSQL()    { psql "$@"; }
  PGREADY() { pg_isready -h "$PGHOST" -p "$PGPORT" >/dev/null 2>&1; }
  AUTH_TCP(){ psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$1" -tAqc "SELECT 1" >/dev/null 2>&1; }
fi

TS="$(date +%Y%m%d_%H%M%S)_$$"
TESTDB="dokandar_pgtest_${TS}"
TESTROLE="dokandar_pgtestrole_${TS}"
RESULT_FILE="$HERE/test-result.txt"

PASS=0; FAIL=0
adm()  { PSQL -v ON_ERROR_STOP=1 -d postgres   -tAqc "$1"; }   # against the admin DB
tst()  { PSQL -v ON_ERROR_STOP=1 -d "$TESTDB"  -tAqc "$1"; }   # against the throwaway DB
eq()   { # eq "name" "expected" "actual"
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %-44s [%s]\n' "$1" "$3"
  else                     FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %-44s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
yes() { # yes "name" "1|0"   (1 = pass)
  if [ "$2" = "1" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %-44s\n' "$1"
  else                    FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %-44s\n' "$1"; fi; }

# ---- cleanup: idempotent, FORCE-drop from the admin DB, never fails the script ---------------
cleanup() {
  PSQL -d postgres -tAqc "DROP DATABASE IF EXISTS ${TESTDB} WITH (FORCE);" >/dev/null 2>&1 || true
  PSQL -d postgres -tAqc "DROP ROLE IF EXISTS ${TESTROLE};"               >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> PostgreSQL test   host=${PGHOST}:${PGPORT}  user=${PGUSER}  testdb=${TESTDB}  [mode=${RUNMODE}${CON:+ via ${CON}}]"

# 0. connectivity + version (fail fast if the server is not up). In docker mode PGREADY hits the
#    PUBLISHED port via a host-network container, so this gate proves the real path — not just a socket.
if ! PGREADY; then
  printf '  \033[31m✗\033[0m pg_isready: server not accepting connections on %s:%s\n' "$PGHOST" "$PGPORT"
  echo "RESULT: FAIL (no server)"; exit 1
fi
VER="$(adm "SHOW server_version;" 2>/dev/null || true)"
yes "pg_isready + version (${VER:-?})" "$([ -n "$VER" ] && echo 1 || echo 0)"

# 1. create the throwaway database + role
adm "CREATE DATABASE ${TESTDB};" >/dev/null 2>&1
eq  "create database"            "1" "$(adm "SELECT 1 FROM pg_database WHERE datname='${TESTDB}'")"
adm "CREATE ROLE ${TESTROLE} NOLOGIN;" >/dev/null 2>&1
eq  "create role"                "1" "$(adm "SELECT 1 FROM pg_roles WHERE rolname='${TESTROLE}'")"

# 2. DDL — types, PK, CHECK, UNIQUE, index
tst "CREATE TABLE t (id bigserial PRIMARY KEY, name_bn text, name_en text, qty int CHECK (qty >= 0), price_minor bigint, created_at timestamptz DEFAULT now(), UNIQUE(name_en));" >/dev/null 2>&1
eq  "create table"               "t" "$(tst "SELECT tablename FROM pg_tables WHERE tablename='t'")"

# 3. DML — insert / aggregate (bilingual UTF-8 content)
tst "INSERT INTO t(name_bn,name_en,qty,price_minor) VALUES ('চাল','rice',100,5500),('ডাল','lentil',50,12000),('তেল','oil',0,25000);" >/dev/null 2>&1
eq  "insert 3 rows"              "3"   "$(tst "SELECT count(*) FROM t")"
eq  "aggregate sum(qty)"        "150" "$(tst "SELECT sum(qty) FROM t")"
eq  "utf-8 bangla round-trip"   "চাল" "$(tst "SELECT name_bn FROM t WHERE name_en='rice'")"

# 4. update
tst "UPDATE t SET qty=qty+10 WHERE name_en='oil';" >/dev/null 2>&1
eq  "update row"                "10"  "$(tst "SELECT qty FROM t WHERE name_en='oil'")"

# 5. transaction rollback leaves no trace
tst "BEGIN; INSERT INTO t(name_en,qty,price_minor) VALUES('temp',1,1); ROLLBACK;" >/dev/null 2>&1
eq  "transaction rollback"      "3"   "$(tst "SELECT count(*) FROM t")"

# 6. EXPECTED-FAILURE tests — constraints MUST reject (wrapped, never bare under any strict mode)
if tst "INSERT INTO t(name_en,qty,price_minor) VALUES('rice',1,1);" >/dev/null 2>&1; then yes "UNIQUE violation rejected" 0; else yes "UNIQUE violation rejected" 1; fi
if tst "INSERT INTO t(name_en,qty,price_minor) VALUES('neg',-5,1);"  >/dev/null 2>&1; then yes "CHECK(qty>=0) rejected"    0; else yes "CHECK(qty>=0) rejected"    1; fi

# 7. extensions DOKANDAR services rely on (+ a real similarity query)
eq  "ext pg_trgm"        "1" "$(tst "CREATE EXTENSION IF NOT EXISTS pg_trgm; SELECT 1 FROM pg_extension WHERE extname='pg_trgm'")"
eq  "ext cube"           "1" "$(tst "CREATE EXTENSION IF NOT EXISTS cube; SELECT 1 FROM pg_extension WHERE extname='cube'")"
eq  "ext earthdistance"  "1" "$(tst "CREATE EXTENSION IF NOT EXISTS earthdistance; SELECT 1 FROM pg_extension WHERE extname='earthdistance'")"
eq  "pg_trgm similarity" "1" "$(tst "SELECT (similarity('rice','rici') > 0)::int")"
eq  "gin_trgm_ops index" "t_trgm" "$(tst "CREATE INDEX t_trgm ON t USING gin (name_en gin_trgm_ops); SELECT indexname FROM pg_indexes WHERE indexname='t_trgm'")"

# 8. TCP/scram auth round-trip over the PUBLISHED port (only when a password is available).
#    In docker mode AUTH_TCP goes through `docker run --network host`, so this asserts the real port.
if [ -n "${PGPASSWORD:-}" ]; then
  if AUTH_TCP "$TESTDB"; then yes "TCP/scram auth login (published port)" 1; else yes "TCP/scram auth login (published port)" 0; fi
fi

# ---- explicit cleanup, then PROVE zero residue (this post-check is the 'cleaned up' evidence) -
cleanup
eq  "post-clean: 0 test databases" "0" "$(adm "SELECT count(*) FROM pg_database WHERE datname LIKE 'dokandar_pgtest_%'")"
eq  "post-clean: 0 test roles"     "0" "$(adm "SELECT count(*) FROM pg_roles    WHERE rolname LIKE 'dokandar_pgtestrole_%'")"

# ---- report (the result is the report; the data is gone) -------------------------------------
TOTAL=$((PASS+FAIL)); STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SUMMARY="PostgreSQL test @ ${STAMP}  host=${PGHOST}:${PGPORT}  server_version=${VER:-?}  mode=${RUNMODE}  ->  ${PASS}/${TOTAL} PASS, ${FAIL} FAIL"
echo ""
echo "=================================================================="
printf '%s\n' "$SUMMARY"
[ "$RUNMODE" = docker ] && printf 'ran via Docker: DDL/DML through container "%s" socket; connectivity + auth verified on the PUBLISHED port %s:%s.\n  (install postgresql-client-%s for a pure host-side run.)\n' "$CON" "$PGHOST" "$PGPORT" "${POSTGRES_VERSION:-18}"
echo "=================================================================="
printf '%s\n' "$SUMMARY" > "$RESULT_FILE" 2>/dev/null || true
if [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS — all test objects dropped, zero residue."; exit 0
else                       echo "RESULT: FAIL ($FAIL failing)"; exit 1; fi
