#!/usr/bin/env bash
# DOKANDAR — ClickHouse contract/smoke test (HTTP interface, via curl). Tests ANY ClickHouse (single or
# a Keeper-coordinated cluster node). Confirms connectivity+auth (SELECT 1), then creates a THROWAWAY
# database + MergeTree table, inserts bilingual-UTF-8 rows, reads them back (count / value / aggregate),
# then DROPS the database and PROVES zero residue. Touches nothing else.
#
#   Usage:  bash test.sh [TARGET]
#     TARGET: a variant folder — bash test.sh 03_docker_single   (reads user/password + port from .env)
#             a host           — bash test.sh 172.31.9.71        (then pass creds via env)
#     Resolves CLICKHOUSE_HOST, CLICKHOUSE_HTTP_PORT, CLICKHOUSE_USER, CLICKHOUSE_PASSWORD from the TARGET
#     folder's .env, this folder's .env, or the environment.
#   Client: curl (host) or a curlimages/curl Docker container (--network host). No host packages needed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

ARG="${1:-}"; ENVF=""
case "$ARG" in
  "")         : ;;
  *.env|*/*)  ENVF="$ARG" ;;
  *[a-zA-Z]*) [ -d "$HERE/$ARG" ] && ENVF="$HERE/$ARG/.env" || CLICKHOUSE_HOST="$ARG" ;;
  *)          CLICKHOUSE_HOST="$ARG" ;;
esac
if [ -n "$ENVF" ] && [ -r "$ENVF" ]; then set -a; . "$ENVF"; set +a
elif [ -z "${CLICKHOUSE_HOST:-}" ] && [ -r "$HERE/.env" ]; then set -a; . "$HERE/.env"; set +a; fi

HOST="${CLICKHOUSE_HOST:-${HOST_IP:-127.0.0.1}}"; PORT="${CLICKHOUSE_HTTP_PORT:-8123}"
USER="${CLICKHOUSE_USER:-default}"; PASSWORD="${CLICKHOUSE_PASSWORD:-}"; BASE="http://${HOST}:${PORT}"

if command -v curl >/dev/null 2>&1; then RUNMODE=host; CURL(){ curl "$@"; }
elif command -v docker >/dev/null 2>&1; then
  RUNMODE=docker; docker image inspect curlimages/curl:latest >/dev/null 2>&1 || docker pull -q curlimages/curl:latest >/dev/null 2>&1 || true
  CURL(){ docker run --rm -i --network host curlimages/curl:latest "$@"; }
else echo "  ✗ no curl and no docker"; echo "RESULT: FAIL (no client)"; exit 2; fi
# Run one SQL statement over the HTTP interface; stdin carries the query. Basic-auth user:password.
q(){ printf '%s' "$1" | CURL -s --max-time 30 -u "${USER}:${PASSWORD}" "${BASE}/" --data-binary @- 2>/dev/null; }

TS="$(date +%Y%m%d%H%M%S)$$"; DB="dokandar_test_${TS}"; RESULT_FILE="$HERE/test-result.txt"
PASS=0; FAIL=0
eq(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %-32s [%s]\n' "$1" "$3"
      else FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %-32s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ q "DROP DATABASE IF EXISTS \`${DB}\`" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> ClickHouse test   ${BASE}   db=${DB}   [mode=${RUNMODE}]"

# 0. connectivity + auth
ONE="$(q 'SELECT 1')"
if [ "$ONE" != "1" ]; then printf '  \033[31m✗\033[0m not reachable / auth failed at %s\n  %s\n' "$BASE" "$ONE"; echo "RESULT: FAIL (no server)"; exit 1; fi
VER="$(q 'SELECT version()')"; echo "  reachable; ClickHouse v${VER:-?}"
eq "connectivity (SELECT 1)" "1" "$ONE"

# 1. create db + MergeTree table
q "CREATE DATABASE \`${DB}\`" >/dev/null 2>&1
q "CREATE TABLE \`${DB}\`.t (id UInt64, name String) ENGINE=MergeTree ORDER BY id" >/dev/null 2>&1
# 2. insert bilingual UTF-8 rows
q "INSERT INTO \`${DB}\`.t VALUES (1,'চাল-rice'),(2,'ডিম-egg'),(3,'মাছ-fish')" >/dev/null 2>&1
# 3. read back: count / UTF-8 value / aggregate
eq "row count"           "3"        "$(q "SELECT count() FROM \`${DB}\`.t")"
eq "UTF-8 value (id=1)"  "চাল-rice" "$(q "SELECT name FROM \`${DB}\`.t WHERE id=1")"
eq "aggregate sum(id)"   "6"        "$(q "SELECT sum(id) FROM \`${DB}\`.t")"

# 4. drop + PROVE zero residue
cleanup; sleep 1
eq "post-clean: db gone" "0" "$(q "SELECT count() FROM system.databases WHERE name='${DB}'")"

TOTAL=$((PASS+FAIL)); STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SUMMARY="ClickHouse test @ ${STAMP}  ${BASE}  v${VER:-?}  mode=${RUNMODE}  ->  ${PASS}/${TOTAL} PASS, ${FAIL} FAIL"
echo ""; echo "=================================================================="
printf '%s\n' "$SUMMARY"; echo "=================================================================="
printf '%s\n' "$SUMMARY" > "$RESULT_FILE" 2>/dev/null || true
if [ "$TOTAL" -gt 0 ] && [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS — table created/written/read/dropped, zero residue."; exit 0
else echo "RESULT: FAIL (${FAIL} failing)"; exit 1; fi
