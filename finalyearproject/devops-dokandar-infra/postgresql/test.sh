#!/usr/bin/env bash
# PostgreSQL contract/smoke test — proves the instance genuinely works.
# Creates a THROWAWAY database dki_pgtest_<ts>, exercises DDL/DML/UTF-8/transactions/
# constraint rejection, then DROPS everything and PROVES zero residue.
#
#   bash test.sh                          -> uses docker-single-node-setup/.env
#   bash test.sh docker-single-node-setup -> same, explicit
#   bash test.sh "postgresql://user:pass@host:port/db"
#   PGHOST=.. PGPORT=.. PGUSER=.. PGPASSWORD=.. bash test.sh
# NOT `set -e`: some statements are EXPECTED to fail (constraint tests).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# ---- resolve connection: URL arg > variant .env > this-dir .env > env vars > defaults ----
ARG="${1:-}"; CONNURL=""
case "$ARG" in
  postgres://*|postgresql://*) CONNURL="$ARG" ;;
  "") for f in "$HERE"/.env "$HERE"/*-setup/.env; do [ -r "$f" ] && { set -a; . "$f"; set +a; break; }; done ;;
  *)  ENVF="$HERE/$ARG/.env"; [ -f "$ARG" ] && ENVF="$ARG"
      [ -r "$ENVF" ] && { set -a; . "$ENVF"; set +a; } || echo "  ! env not readable: $ENVF" >&2 ;;
esac
if [ -n "$CONNURL" ]; then
  u="${CONNURL#postgres://}"; u="${u#postgresql://}"; u="${u%%\?*}"
  creds="${u%@*}"; hostpart="${u##*@}"; hostpart="${hostpart%%/*}"
  PGUSER="${creds%%:*}"; PGPASSWORD="${creds#*:}"
  PGHOST="${hostpart%%:*}"; PGPORT="${hostpart#*:}"
fi
export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-${POSTGRES_PORT:-5432}}"
export PGUSER="${PGUSER:-${POSTGRES_USER:-dki}}"
export PGPASSWORD="${PGPASSWORD:-${POSTGRES_PASSWORD:-}}"

# ---- client: host psql, else run psql inside the serving container ----
if command -v psql >/dev/null 2>&1; then
  MODE=host; PSQL(){ psql "$@"; }
else
  CON="$(docker ps --format '{{.Names}}\t{{.Ports}}' | awk -F'\t' -v p=":${PGPORT}->" 'index($2,p){print $1; exit}')"
  [ -z "$CON" ] && { echo "no psql client and no local container on :${PGPORT}"; echo "RESULT: FAIL"; exit 2; }
  MODE="docker via ${CON}"
  PSQL(){ docker exec -i -e PGPASSWORD="$PGPASSWORD" "$CON" psql -h 127.0.0.1 -U "$PGUSER" "$@"; }
fi

TS="$(date +%s)_$$"; TESTDB="dki_pgtest_${TS}"; RESULT_FILE="$HERE/test-result.txt"
PASS=0; FAIL=0
adm(){ PSQL -v ON_ERROR_STOP=1 -d postgres  -tAqc "$1"; }
tst(){ PSQL -v ON_ERROR_STOP=1 -d "$TESTDB" -tAqc "$1"; }
eq(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %-40s [%s]\n' "$1" "$3"
     else FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %-40s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
yes(){ if [ "$2" = 1 ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"
      else FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; fi; }
cleanup(){ PSQL -d postgres -tAqc "DROP DATABASE IF EXISTS ${TESTDB} WITH (FORCE);" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> PostgreSQL test  ${PGHOST}:${PGPORT} user=${PGUSER} [mode=${MODE}]"
VER="$(adm 'SHOW server_version;' 2>/dev/null || true)"
yes "connect + version (${VER:-none})" "$([ -n "$VER" ] && echo 1 || echo 0)"
[ -z "$VER" ] && { echo "RESULT: FAIL (no server)"; exit 1; }

adm "CREATE DATABASE ${TESTDB};" >/dev/null 2>&1
eq "create throwaway database" "1" "$(adm "SELECT 1 FROM pg_database WHERE datname='${TESTDB}'")"

tst "CREATE TABLE t (id bigserial PRIMARY KEY, name_bn text, name_en text UNIQUE, qty int CHECK (qty>=0));" >/dev/null 2>&1
eq "create table (PK/UNIQUE/CHECK)" "t" "$(tst "SELECT tablename FROM pg_tables WHERE tablename='t'")"
tst "INSERT INTO t(name_bn,name_en,qty) VALUES ('চাল','rice',100),('ডাল','lentil',50),('তেল','oil',0);" >/dev/null 2>&1
eq "insert 3 rows"            "3"    "$(tst 'SELECT count(*) FROM t')"
eq "aggregate sum"            "150"  "$(tst 'SELECT sum(qty) FROM t')"
eq "utf-8 bangla round-trip"  "চাল"  "$(tst "SELECT name_bn FROM t WHERE name_en='rice'")"
tst "BEGIN; DELETE FROM t; ROLLBACK;" >/dev/null 2>&1
eq "transaction rollback"     "3"    "$(tst 'SELECT count(*) FROM t')"
if tst "INSERT INTO t(name_en,qty) VALUES('rice',1);" >/dev/null 2>&1; then yes "UNIQUE violation rejected" 0; else yes "UNIQUE violation rejected" 1; fi
if tst "INSERT INTO t(name_en,qty) VALUES('neg',-1);" >/dev/null 2>&1; then yes "CHECK violation rejected" 0; else yes "CHECK violation rejected" 1; fi
eq "ext pg_trgm + similarity" "1" "$(tst "CREATE EXTENSION IF NOT EXISTS pg_trgm; SELECT (similarity('rice','rici')>0)::int")"

cleanup
eq "post-clean: zero residue" "0" "$(adm "SELECT count(*) FROM pg_database WHERE datname LIKE 'dki_pgtest_%'")"

TOTAL=$((PASS+FAIL))
SUMMARY="PostgreSQL test @ $(date -u +%FT%TZ)  ${PGHOST}:${PGPORT}  v${VER}  -> ${PASS}/${TOTAL} PASS, ${FAIL} FAIL"
echo; echo "$SUMMARY"; echo "$SUMMARY" > "$RESULT_FILE"
[ "$FAIL" -eq 0 ] && { echo "RESULT: PASS — all test objects dropped, zero residue."; exit 0; } \
                  || { echo "RESULT: FAIL"; exit 1; }
