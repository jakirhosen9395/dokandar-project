#!/usr/bin/env bash
# ClickHouse contract test — via the HTTP interface: throwaway db dki_chtest_<ts>, MergeTree
# table, insert/aggregate/UTF-8, wrong-password rejection, drop db, prove zero residue.
#   bash test.sh [docker-single-node-setup]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARG="${1:-}"
case "$ARG" in
  "") for f in "$HERE"/.env "$HERE"/*-setup/.env; do [ -r "$f" ] && { set -a; . "$f"; set +a; break; }; done ;;
  *)  ENVF="$HERE/$ARG/.env"; [ -r "$ENVF" ] && { set -a; . "$ENVF"; set +a; } ;;
esac
HOST="${CLICKHOUSE_HOST:-127.0.0.1}"; PORT="${CLICKHOUSE_HTTP_PORT:-8123}"
USER_="${CLICKHOUSE_USER:-dki}"; PASS_="${CLICKHOUSE_PASSWORD:-}"
BASE="http://${HOST}:${PORT}/"
Q(){ curl -s "${BASE}" --data-binary "$1" -H "X-ClickHouse-User: ${USER_}" -H "X-ClickHouse-Key: ${PASS_}"; }

TS="$(date +%s)_$$"; DB="dki_chtest_${TS}"; RESULT_FILE="$HERE/test-result.txt"; P=0; F=0
eq(){ if [ "$2" = "$3" ]; then P=$((P+1)); printf '  \033[32m✓\033[0m %-36s [%s]\n' "$1" "$3"
     else F=$((F+1)); printf '  \033[31m✗\033[0m %-36s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ Q "DROP DATABASE IF EXISTS ${DB}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> ClickHouse test  ${HOST}:${PORT} user=${USER_} (HTTP)"
VER="$(Q 'SELECT version()' 2>/dev/null | tr -d '\n')"
eq "connect + version (${VER:-none})" "ok" "$([ -n "$VER" ] && echo ok || echo no)"
[ -z "$VER" ] && { echo "RESULT: FAIL (no server)"; exit 1; }
Q "CREATE DATABASE ${DB}" >/dev/null 2>&1
eq "create database"        "1"    "$(Q "SELECT count() FROM system.databases WHERE name='${DB}'" | tr -d '\n')"
Q "CREATE TABLE ${DB}.t (name_en String, name_bn String, qty Int32) ENGINE=MergeTree ORDER BY name_en" >/dev/null 2>&1
Q "INSERT INTO ${DB}.t VALUES ('rice','চাল',100),('lentil','ডাল',50),('oil','তেল',0)" >/dev/null 2>&1
eq "insert 3 rows"          "3"    "$(Q "SELECT count() FROM ${DB}.t" | tr -d '\n')"
eq "aggregate sum"          "150"  "$(Q "SELECT sum(qty) FROM ${DB}.t" | tr -d '\n')"
eq "utf-8 bangla round-trip" "চাল" "$(Q "SELECT name_bn FROM ${DB}.t WHERE name_en='rice'" | tr -d '\n')"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}" --data-binary 'SELECT 1' -H "X-ClickHouse-User: ${USER_}" -H "X-ClickHouse-Key: WRONG")"
eq "wrong password rejected" "not-200" "$([ "$CODE" = 200 ] && echo 200 || echo not-200)"
cleanup
eq "post-clean: zero residue" "0" "$(Q "SELECT count() FROM system.databases WHERE name LIKE 'dki_chtest_%'" | tr -d '\n')"

TOTAL=$((P+F)); SUMMARY="ClickHouse test @ $(date -u +%FT%TZ)  ${HOST}:${PORT}  v${VER}  -> ${P}/${TOTAL} PASS, ${F} FAIL"
echo; echo "$SUMMARY"; echo "$SUMMARY" > "$RESULT_FILE"
[ "$F" -eq 0 ] && { echo "RESULT: PASS — test database dropped, zero residue."; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
