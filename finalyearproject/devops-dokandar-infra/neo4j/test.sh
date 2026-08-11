#!/usr/bin/env bash
# Neo4j contract test — via cypher-shell in the container: create throwaway :DkiTest nodes +
# a relationship, query them (UTF-8), delete them, prove zero residue.
#   bash test.sh [docker-single-node-setup]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARG="${1:-}"
case "$ARG" in
  "") for f in "$HERE"/.env "$HERE"/*-setup/.env; do [ -r "$f" ] && { set -a; . "$f"; set +a; break; }; done ;;
  *)  ENVF="$HERE/$ARG/.env"; [ -r "$ENVF" ] && { set -a; . "$ENVF"; set +a; } ;;
esac
HOST="${NEO4J_HOST:-127.0.0.1}"; BOLT="${NEO4J_BOLT_PORT:-7687}"; PASS_="${NEO4J_PASSWORD:-}"
CON="$(docker ps --format '{{.Names}}' | grep -x dki_neo4j || true)"
[ -z "$CON" ] && { echo "neo4j container not running"; echo "RESULT: FAIL"; exit 2; }
CY(){ docker exec -i "$CON" cypher-shell -u neo4j -p "$PASS_" --format plain "$1" 2>/dev/null | tail -n +2; }

RESULT_FILE="$HERE/test-result.txt"; P=0; F=0; TAG="dki_test_$(date +%s)_$$"
eq(){ if [ "$2" = "$3" ]; then P=$((P+1)); printf '  \033[32m✓\033[0m %-36s [%s]\n' "$1" "$3"
     else F=$((F+1)); printf '  \033[31m✗\033[0m %-36s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ CY "MATCH (n:DkiTest {tag:'${TAG}'}) DETACH DELETE n" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Neo4j test  ${HOST}:${BOLT} user=neo4j (cypher-shell in ${CON})"
eq "connect (RETURN 1)"   "1"   "$(CY 'RETURN 1' | tr -d ' ')"
[ "$(CY 'RETURN 1' | tr -d ' ')" != 1 ] && { echo "RESULT: FAIL (no server)"; exit 1; }
CY "CREATE (:DkiTest {tag:'${TAG}', name_en:'rice', name_bn:'চাল'}),(:DkiTest {tag:'${TAG}', name_en:'lentil', name_bn:'ডাল'})" >/dev/null 2>&1
eq "create 2 nodes"       "2"   "$(CY "MATCH (n:DkiTest {tag:'${TAG}'}) RETURN count(n)" | tr -d ' ')"
eq "utf-8 bangla round-trip" "চাল" "$(CY "MATCH (n:DkiTest {tag:'${TAG}', name_en:'rice'}) RETURN n.name_bn" | tr -d ' \"')"
CY "MATCH (a:DkiTest {tag:'${TAG}', name_en:'rice'}),(b:DkiTest {tag:'${TAG}', name_en:'lentil'}) CREATE (a)-[:SUPPLIES]->(b)" >/dev/null 2>&1
eq "create relationship"  "1"   "$(CY "MATCH (:DkiTest {tag:'${TAG}'})-[r:SUPPLIES]->() RETURN count(r)" | tr -d ' ')"
cleanup
eq "post-clean: zero residue" "0" "$(CY "MATCH (n:DkiTest {tag:'${TAG}'}) RETURN count(n)" | tr -d ' ')"

TOTAL=$((P+F)); SUMMARY="Neo4j test @ $(date -u +%FT%TZ)  ${HOST}:${BOLT}  -> ${P}/${TOTAL} PASS, ${F} FAIL"
echo; echo "$SUMMARY"; echo "$SUMMARY" > "$RESULT_FILE"
[ "$F" -eq 0 ] && { echo "RESULT: PASS — test nodes deleted, zero residue."; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
