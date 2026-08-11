#!/usr/bin/env bash
# DOKANDAR — Neo4j contract/smoke test (HTTP Cypher transaction API, via curl). Tests ANY Neo4j (single
# node or a cluster member). Confirms connectivity+auth (RETURN 1), then creates a THROWAWAY labelled
# subgraph (nodes + a relationship, bilingual-UTF-8 props), reads it back (count / value / relationship),
# then DETACH DELETEs that label and PROVES zero residue. Touches nothing else (its own unique label).
#
#   Usage:  bash test.sh [TARGET]
#     TARGET: a variant folder — bash test.sh 03_docker_single   (reads user/password + port from .env)
#             a host           — bash test.sh 172.31.9.71        (then pass creds via env)
#     Resolves NEO4J_HOST, NEO4J_HTTP_PORT, NEO4J_USER, NEO4J_PASSWORD from the TARGET folder's .env, this
#     folder's .env, or the environment.
#   Client: curl (host) or a curlimages/curl Docker container (--network host). No host packages needed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

ARG="${1:-}"; ENVF=""
case "$ARG" in
  "")         : ;;
  *.env|*/*)  ENVF="$ARG" ;;
  *[a-zA-Z]*) [ -d "$HERE/$ARG" ] && ENVF="$HERE/$ARG/.env" || NEO4J_HOST="$ARG" ;;
  *)          NEO4J_HOST="$ARG" ;;
esac
if [ -n "$ENVF" ] && [ -r "$ENVF" ]; then set -a; . "$ENVF"; set +a
elif [ -z "${NEO4J_HOST:-}" ] && [ -r "$HERE/.env" ]; then set -a; . "$HERE/.env"; set +a; fi

HOST="${NEO4J_HOST:-${HOST_IP:-127.0.0.1}}"; PORT="${NEO4J_HTTP_PORT:-7474}"
USER="${NEO4J_USER:-neo4j}"; PASSWORD="${NEO4J_PASSWORD:-}"; BASE="http://${HOST}:${PORT}"

if command -v curl >/dev/null 2>&1; then RUNMODE=host; CURL(){ curl "$@"; }
elif command -v docker >/dev/null 2>&1; then
  RUNMODE=docker; docker image inspect curlimages/curl:latest >/dev/null 2>&1 || docker pull -q curlimages/curl:latest >/dev/null 2>&1 || true
  CURL(){ docker run --rm -i --network host curlimages/curl:latest "$@"; }
else echo "  ✗ no curl and no docker"; echo "RESULT: FAIL (no client)"; exit 2; fi
# run one Cypher statement over the HTTP transaction endpoint; returns the JSON response.
# (Statements here use single-quoted Cypher string literals, so there are no " to escape into the JSON.)
cy(){ CURL -s --max-time 30 -u "${USER}:${PASSWORD}" -H 'content-type: application/json' -H 'accept: application/json' \
      "${BASE}/db/neo4j/tx/commit" -d "{\"statements\":[{\"statement\":\"$1\"}]}" 2>/dev/null; }
# first scalar in the first row of the response
rowval(){ printf '%s' "$1" | grep -oE '"row":\[[^]]*\]' | head -1 | sed -E 's/"row":\[(.*)\]/\1/; s/^"//; s/"$//'; }

TS="$(date +%Y%m%d%H%M%S)$$"; L="DokTest_${TS}"; RESULT_FILE="$HERE/test-result.txt"
PASS=0; FAIL=0
eq(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %-32s [%s]\n' "$1" "$3"
      else FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %-32s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ cy "MATCH (n:${L}) DETACH DELETE n" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Neo4j test   ${BASE}   label=${L}   [mode=${RUNMODE}]"

# 0. connectivity + auth
R0="$(cy 'RETURN 1')"
ONE="$(rowval "$R0")"
if [ "$ONE" != "1" ]; then printf '  \033[31m✗\033[0m RETURN 1 -> "%s" (auth wrong or unreachable) at %s\n' "$ONE" "$BASE"; echo "RESULT: FAIL (no server)"; exit 1; fi
VER="$(rowval "$(cy 'CALL dbms.components() YIELD versions RETURN versions[0]')")"
echo "  reachable; Neo4j v${VER:-?}"
eq "connectivity (RETURN 1)" "1" "$ONE"

# 1. create a labelled subgraph: 3 nodes + 1 relationship (bilingual UTF-8)
cy "CREATE (a:${L} {id:1, name:'চাল-rice'}), (b:${L} {id:2, name:'ডিম-egg'}), (c:${L} {id:3, name:'মাছ-fish'}) CREATE (a)-[:NEXT]->(b)" >/dev/null 2>&1
# 2. read back: node count / UTF-8 value / relationship count
eq "node count"        "3"        "$(rowval "$(cy "MATCH (n:${L}) RETURN count(n)")")"
eq "UTF-8 property"    "চাল-rice" "$(rowval "$(cy "MATCH (n:${L} {id:1}) RETURN n.name")")"
eq "relationship count" "1"       "$(rowval "$(cy "MATCH (:${L})-[r:NEXT]->(:${L}) RETURN count(r)")")"

# 3. detach delete + PROVE zero residue
cleanup; sleep 1
eq "post-clean: label gone" "0" "$(rowval "$(cy "MATCH (n:${L}) RETURN count(n)")")"

TOTAL=$((PASS+FAIL)); STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SUMMARY="Neo4j test @ ${STAMP}  ${BASE}  v${VER:-?}  mode=${RUNMODE}  ->  ${PASS}/${TOTAL} PASS, ${FAIL} FAIL"
echo ""; echo "=================================================================="
printf '%s\n' "$SUMMARY"; echo "=================================================================="
printf '%s\n' "$SUMMARY" > "$RESULT_FILE" 2>/dev/null || true
if [ "$TOTAL" -gt 0 ] && [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS — subgraph created/queried/deleted, zero residue."; exit 0
else echo "RESULT: FAIL (${FAIL} failing)"; exit 1; fi
