#!/usr/bin/env bash
# ScyllaDB contract test — via cqlsh in the container: throwaway keyspace + table,
# INSERT/SELECT round-trip (UTF-8), UPDATE counter-style, DROP keyspace, zero residue.
#   bash test.sh [docker-single-node-setup]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARG="${1:-}"
case "$ARG" in
  "") for f in "$HERE"/.env "$HERE"/*-setup/.env; do [ -r "$f" ] && { set -a; . "$f"; set +a; break; }; done ;;
  *)  ENVF="$HERE/$ARG/.env"; [ -r "$ENVF" ] && { set -a; . "$ENVF"; set +a; } ;;
esac
CON="$(docker ps --format '{{.Names}}' | grep -x dki_scylla || true)"
[ -z "$CON" ] && { echo "scylla container not running"; echo "RESULT: FAIL"; exit 2; }
CQL(){ docker exec -i "$CON" cqlsh -e "$1" 2>/dev/null; }

TS="$(date +%s)_$$"; KS="dki_test_${TS}"; RESULT_FILE="$HERE/test-result.txt"; P=0; F=0
eq(){ if [ "$2" = "$3" ]; then P=$((P+1)); printf '  \033[32m✓\033[0m %-36s [%s]\n' "$1" "$3"
     else F=$((F+1)); printf '  \033[31m✗\033[0m %-36s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ CQL "DROP KEYSPACE IF EXISTS ${KS}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> ScyllaDB test  (cqlsh in ${CON})"
VER="$(CQL 'SELECT release_version FROM system.local' | sed -n 4p | tr -d ' ')"
eq "connect + version (${VER:-none})" "ok" "$([ -n "$VER" ] && echo ok || echo no)"
[ -z "$VER" ] && { echo "RESULT: FAIL (no server)"; exit 1; }
CQL "CREATE KEYSPACE ${KS} WITH replication = {'class':'SimpleStrategy','replication_factor':1}" >/dev/null
eq "create keyspace" "ok" "$(CQL "DESCRIBE KEYSPACE ${KS}" >/dev/null && echo ok || echo no)"
CQL "CREATE TABLE ${KS}.items (name_en text PRIMARY KEY, name_bn text, qty int)" >/dev/null
CQL "INSERT INTO ${KS}.items (name_en,name_bn,qty) VALUES ('rice','চাল',100)" >/dev/null
CQL "INSERT INTO ${KS}.items (name_en,name_bn,qty) VALUES ('lentil','ডাল',50)" >/dev/null
eq "insert + count" "2" "$(CQL "SELECT count(*) FROM ${KS}.items" | sed -n 4p | tr -d ' ')"
eq "utf-8 bangla round-trip" "চাল" "$(CQL "SELECT name_bn FROM ${KS}.items WHERE name_en='rice'" | sed -n 4p | tr -d ' ')"
CQL "UPDATE ${KS}.items SET qty=60 WHERE name_en='lentil'" >/dev/null
eq "update row" "60" "$(CQL "SELECT qty FROM ${KS}.items WHERE name_en='lentil'" | sed -n 4p | tr -d ' ')"
cleanup
eq "post-clean: zero residue" "0" "$(CQL "SELECT keyspace_name FROM system_schema.keyspaces" | grep -c "dki_test_" || true)"

TOTAL=$((P+F)); SUMMARY="ScyllaDB test @ $(date -u +%FT%TZ)  -> ${P}/${TOTAL} PASS, ${F} FAIL"
echo; echo "$SUMMARY"; echo "$SUMMARY" > "$RESULT_FILE"
[ "$F" -eq 0 ] && { echo "RESULT: PASS — keyspace dropped, zero residue."; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
