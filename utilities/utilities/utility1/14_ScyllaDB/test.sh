#!/usr/bin/env bash
# DOKANDAR — ScyllaDB contract/smoke test (CQL, via cqlsh). Tests ANY ScyllaDB (single node or a cluster
# member). Confirms connectivity, then creates a THROWAWAY keyspace + table, inserts bilingual-UTF-8 rows,
# reads them back (count / value), then DROPS the keyspace and PROVES zero residue. Touches nothing else.
#
#   Usage:  bash test.sh [TARGET]
#     TARGET: a variant folder — bash test.sh 03_docker_single   (reads host/port from .env)
#             a host           — bash test.sh 172.31.9.71
#     Resolves SCYLLA_HOST, SCYLLA_CQL_PORT from the TARGET folder's .env, this folder's .env, or the env.
#   Client: cqlsh (host) or `cqlsh` inside a scylladb/scylla Docker container (--network host). ScyllaDB
#   has no auth by default and no browser UI (it is a CQL database).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

ARG="${1:-}"; ENVF=""
case "$ARG" in
  "")         : ;;
  *.env|*/*)  ENVF="$ARG" ;;
  *[a-zA-Z]*) [ -d "$HERE/$ARG" ] && ENVF="$HERE/$ARG/.env" || SCYLLA_HOST="$ARG" ;;
  *)          SCYLLA_HOST="$ARG" ;;
esac
if [ -n "$ENVF" ] && [ -r "$ENVF" ]; then set -a; . "$ENVF"; set +a
elif [ -z "${SCYLLA_HOST:-}" ] && [ -r "$HERE/.env" ]; then set -a; . "$HERE/.env"; set +a; fi

HOST="${SCYLLA_HOST:-${HOST_IP:-127.0.0.1}}"; PORT="${SCYLLA_CQL_PORT:-9042}"
SCY_IMAGE="${SCYLLA_IMAGE:-scylladb/scylla:2026.1}"

if command -v cqlsh >/dev/null 2>&1; then RUNMODE=host; CQL(){ cqlsh "$HOST" "$PORT" --request-timeout=30 -e "$1" 2>/dev/null; }
elif command -v docker >/dev/null 2>&1; then
  RUNMODE=docker; docker image inspect "$SCY_IMAGE" >/dev/null 2>&1 || docker pull -q "$SCY_IMAGE" >/dev/null 2>&1 || true
  CQL(){ docker run --rm --network host --entrypoint cqlsh "$SCY_IMAGE" "$HOST" "$PORT" --request-timeout=30 -e "$1" 2>/dev/null; }
else echo "  ✗ no cqlsh and no docker"; echo "RESULT: FAIL (no client)"; exit 2; fi
jline(){ printf '%s' "$1" | grep -oE '\{.*\}' | head -1; }   # the SELECT JSON result line

TS="$(date +%Y%m%d%H%M%S)$$"; KS="dokandar_test_${TS}"; RESULT_FILE="$HERE/test-result.txt"
PASS=0; FAIL=0
eq(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %-32s [%s]\n' "$1" "$3"
      else FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %-32s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ CQL "DROP KEYSPACE IF EXISTS ${KS};" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> ScyllaDB test   ${HOST}:${PORT}   keyspace=${KS}   [mode=${RUNMODE}]"

# 0. connectivity
VER="$(jline "$(CQL "SELECT JSON release_version FROM system.local;")" | grep -oE '"[0-9][^"]*"' | head -1 | tr -d '"')"
if [ -z "$VER" ]; then printf '  \033[31m✗\033[0m not reachable at %s:%s\n' "$HOST" "$PORT"; echo "RESULT: FAIL (no server)"; exit 1; fi
echo "  reachable; ScyllaDB release ${VER}"
eq "connectivity (release_version)" "ok" "$([ -n "$VER" ] && echo ok || echo no)"

# 1. keyspace + table + rows (bilingual UTF-8) in one cqlsh call
CQL "CREATE KEYSPACE ${KS} WITH replication = {'class':'SimpleStrategy','replication_factor':1};
USE ${KS};
CREATE TABLE t (id int PRIMARY KEY, name text);
INSERT INTO t (id,name) VALUES (1,'চাল-rice');
INSERT INTO t (id,name) VALUES (2,'ডিম-egg');
INSERT INTO t (id,name) VALUES (3,'মাছ-fish');" >/dev/null 2>&1

# 2. read back: count / UTF-8 value
eq "row count" "3" "$(jline "$(CQL "SELECT JSON count(*) FROM ${KS}.t;")" | grep -oE '[0-9]+' | head -1)"
eq "UTF-8 value (id=1)" "চাল-rice" "$(jline "$(CQL "SELECT JSON name FROM ${KS}.t WHERE id=1;")" | grep -oE '"name": *"[^"]*"' | sed -E 's/.*: *"//; s/"$//')"

# 3. drop + PROVE zero residue
cleanup; sleep 1
eq "post-clean: keyspace gone" "no" "$(CQL "SELECT keyspace_name FROM system_schema.keyspaces WHERE keyspace_name='${KS}';" 2>/dev/null | grep -q "${KS}" && echo yes || echo no)"

TOTAL=$((PASS+FAIL)); STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SUMMARY="ScyllaDB test @ ${STAMP}  ${HOST}:${PORT}  rel ${VER:-?}  mode=${RUNMODE}  ->  ${PASS}/${TOTAL} PASS, ${FAIL} FAIL"
echo ""; echo "=================================================================="
printf '%s\n' "$SUMMARY"; echo "=================================================================="
printf '%s\n' "$SUMMARY" > "$RESULT_FILE" 2>/dev/null || true
if [ "$TOTAL" -gt 0 ] && [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS — keyspace created/written/read/dropped, zero residue."; exit 0
else echo "RESULT: FAIL (${FAIL} failing)"; exit 1; fi
