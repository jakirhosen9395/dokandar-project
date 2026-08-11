#!/usr/bin/env bash
# TimescaleDB contract test — proves the TIME-SERIES features, not just Postgres:
# throwaway db -> CREATE EXTENSION timescaledb -> hypertable -> insert time-series rows ->
# time_bucket aggregate -> drop db -> zero residue.
#   bash test.sh [docker-single-node-setup]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARG="${1:-}"
case "$ARG" in
  "") for f in "$HERE"/.env "$HERE"/*-setup/.env; do [ -r "$f" ] && { set -a; . "$f"; set +a; break; }; done ;;
  *)  ENVF="$HERE/$ARG/.env"; [ -r "$ENVF" ] && { set -a; . "$ENVF"; set +a; } ;;
esac
PORT="${TSDB_PORT:-5433}"; USER_="${TSDB_USER:-dki}"; PASS_="${TSDB_PASSWORD:-}"
CON="$(docker ps --format '{{.Names}}\t{{.Ports}}' | awk -F'\t' -v p=":${PORT}->" 'index($2,p){print $1; exit}')"
[ -z "$CON" ] && { echo "no local container on :${PORT}"; echo "RESULT: FAIL"; exit 2; }
PSQL(){ docker exec -i -e PGPASSWORD="$PASS_" "$CON" psql -h 127.0.0.1 -U "$USER_" "$@"; }

TS="$(date +%s)_$$"; DB="dki_tsdbtest_${TS}"; RESULT_FILE="$HERE/test-result.txt"; P=0; F=0
adm(){ PSQL -v ON_ERROR_STOP=1 -d postgres -tAqc "$1"; }
tst(){ PSQL -v ON_ERROR_STOP=1 -d "$DB" -tAqc "$1"; }
eq(){ if [ "$2" = "$3" ]; then P=$((P+1)); printf '  \033[32m✓\033[0m %-38s [%s]\n' "$1" "$3"
     else F=$((F+1)); printf '  \033[31m✗\033[0m %-38s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ PSQL -d postgres -tAqc "DROP DATABASE IF EXISTS ${DB} WITH (FORCE);" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> TimescaleDB test  127.0.0.1:${PORT} (via ${CON})"
VER="$(adm 'SHOW server_version;' 2>/dev/null || true)"
eq "connect (pg ${VER:-none})" "ok" "$([ -n "$VER" ] && echo ok || echo no)"
[ -z "$VER" ] && { echo "RESULT: FAIL (no server)"; exit 1; }
adm "CREATE DATABASE ${DB};" >/dev/null 2>&1
eq "timescaledb extension" "1" "$(tst "CREATE EXTENSION IF NOT EXISTS timescaledb; SELECT 1 FROM pg_extension WHERE extname='timescaledb'")"
tst "CREATE TABLE metrics (time timestamptz NOT NULL, sensor text, value double precision);" >/dev/null 2>&1
eq "create hypertable" "1" "$(tst "SELECT count(*) FROM (SELECT create_hypertable('metrics','time')) s")"
tst "INSERT INTO metrics SELECT now() - (i||' minutes')::interval, 'dhaka-'||(i%2), i*1.5 FROM generate_series(1,60) i;" >/dev/null 2>&1
eq "insert 60 time-series rows" "60" "$(tst 'SELECT count(*) FROM metrics')"
eq "time_bucket aggregate works" "ok" "$(tst "SELECT count(*) > 0 FROM (SELECT time_bucket('15 minutes', time) b, avg(value) FROM metrics GROUP BY b) x LIMIT 1" | grep -q t && echo ok || echo no)"
cleanup
eq "post-clean: zero residue" "0" "$(adm "SELECT count(*) FROM pg_database WHERE datname LIKE 'dki_tsdbtest_%'")"

TOTAL=$((P+F)); SUMMARY="TimescaleDB test @ $(date -u +%FT%TZ)  :${PORT}  -> ${P}/${TOTAL} PASS, ${F} FAIL"
echo; echo "$SUMMARY"; echo "$SUMMARY" > "$RESULT_FILE"
[ "$F" -eq 0 ] && { echo "RESULT: PASS — test database dropped, zero residue."; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
