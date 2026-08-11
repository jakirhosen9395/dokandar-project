#!/usr/bin/env bash
# DOKANDAR — Qdrant contract/smoke test (REST API, via curl). Tests ANY Qdrant (single or a Raft cluster
# peer). Confirms reachability + auth, then creates a THROWAWAY collection, upserts bilingual-UTF-8 points
# with vectors, reads them back (count / payload / ANN search), then DELETES the collection and PROVES zero
# residue. Touches nothing else.
#
#   Usage:  bash test.sh [TARGET]
#     TARGET: a variant folder — bash test.sh 03_docker_single   (reads api-key + port from .env)
#             a host           — bash test.sh 172.31.9.71        (then pass the key via env)
#     Resolves QDRANT_HOST, QDRANT_HTTP_PORT, QDRANT_API_KEY from the TARGET folder's .env, this folder's
#     .env, or the environment.
#   Client: curl (host) or a curlimages/curl Docker container (--network host). No host packages needed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

ARG="${1:-}"; ENVF=""
case "$ARG" in
  "")         : ;;
  *.env|*/*)  ENVF="$ARG" ;;
  *[a-zA-Z]*) [ -d "$HERE/$ARG" ] && ENVF="$HERE/$ARG/.env" || QDRANT_HOST="$ARG" ;;
  *)          QDRANT_HOST="$ARG" ;;
esac
if [ -n "$ENVF" ] && [ -r "$ENVF" ]; then set -a; . "$ENVF"; set +a
elif [ -z "${QDRANT_HOST:-}" ] && [ -r "$HERE/.env" ]; then set -a; . "$HERE/.env"; set +a; fi

HOST="${QDRANT_HOST:-${HOST_IP:-127.0.0.1}}"; PORT="${QDRANT_HTTP_PORT:-6333}"
KEY="${QDRANT_API_KEY:-}"; BASE="http://${HOST}:${PORT}"
KEY_ARGS=(); [ -n "$KEY" ] && KEY_ARGS=(-H "api-key: ${KEY}")

if command -v curl >/dev/null 2>&1; then RUNMODE=host; CURL(){ curl "$@"; }
elif command -v docker >/dev/null 2>&1; then
  RUNMODE=docker; docker image inspect curlimages/curl:latest >/dev/null 2>&1 || docker pull -q curlimages/curl:latest >/dev/null 2>&1 || true
  CURL(){ docker run --rm -i --network host curlimages/curl:latest "$@"; }
else echo "  ✗ no curl and no docker"; echo "RESULT: FAIL (no client)"; exit 2; fi
api(){ local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then CURL -s --max-time 25 "${KEY_ARGS[@]}" -X "$m" -H 'content-type: application/json' "${BASE}${p}" -d "$b"
  else CURL -s --max-time 25 "${KEY_ARGS[@]}" -X "$m" "${BASE}${p}"; fi; }
code(){ CURL -s -o /dev/null -w '%{http_code}' --max-time 10 "${KEY_ARGS[@]}" "${BASE}${1}" 2>/dev/null || echo 000; }

TS="$(date +%Y%m%d%H%M%S)$$"; C="dokandar_test_${TS}"; RESULT_FILE="$HERE/test-result.txt"
PASS=0; FAIL=0
eq(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %-32s [%s]\n' "$1" "$3"
      else FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %-32s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ api DELETE "/collections/${C}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Qdrant test   ${BASE}   collection=${C}   [mode=${RUNMODE}]"

# 0. reachability + auth
RC="$(code /collections)"
if [ "$RC" != 200 ]; then printf '  \033[31m✗\033[0m /collections returned %s (auth/key wrong or unreachable) at %s\n' "$RC" "$BASE"; echo "RESULT: FAIL (no server)"; exit 1; fi
VER="$(api GET / | grep -oE '"version":"[^"]*"' | head -1 | cut -d'"' -f4)"
echo "  reachable; Qdrant v${VER:-?}  /collections=${RC}"

# 1. create a collection (4-dim, Dot distance)
api PUT "/collections/${C}" '{"vectors":{"size":4,"distance":"Dot"}}' >/dev/null 2>&1
eq "create collection" "true" "$(api GET "/collections/${C}" | grep -oE '"status":"green"|"status":"yellow"' | head -1 | grep -q status && echo true || echo false)"
# 2. upsert 3 points (bilingual UTF-8 payloads)
api PUT "/collections/${C}/points?wait=true" '{"points":[
  {"id":1,"vector":[0.9,0.1,0.0,0.0],"payload":{"name":"চাল-rice"}},
  {"id":2,"vector":[0.1,0.9,0.0,0.0],"payload":{"name":"ডিম-egg"}},
  {"id":3,"vector":[0.0,0.0,0.9,0.1],"payload":{"name":"মাছ-fish"}}]}' >/dev/null 2>&1
# 3. count
eq "point count" "3" "$(api POST "/collections/${C}/points/count" '{"exact":true}' | grep -oE '"count":[0-9]+' | head -1 | cut -d: -f2)"
# 4. retrieve by id → UTF-8 payload
eq "retrieve UTF-8 payload" "চাল-rice" "$(api GET "/collections/${C}/points/1" | grep -oE '"name":"[^"]*"' | head -1 | cut -d'"' -f4)"
# 5. ANN search nearest to point 1's vector → top hit id=1
eq "ANN search top id" "1" "$(api POST "/collections/${C}/points/search" '{"vector":[0.9,0.1,0.0,0.0],"limit":1}' | grep -oE '"id":[0-9]+' | head -1 | cut -d: -f2)"

# 6. delete + PROVE zero residue
cleanup; sleep 1
eq "post-clean: collection gone" "no" "$(api GET "/collections" | grep -q "\"${C}\"" && echo yes || echo no)"

TOTAL=$((PASS+FAIL)); STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SUMMARY="Qdrant test @ ${STAMP}  ${BASE}  v${VER:-?}  mode=${RUNMODE}  ->  ${PASS}/${TOTAL} PASS, ${FAIL} FAIL"
echo ""; echo "=================================================================="
printf '%s\n' "$SUMMARY"; echo "=================================================================="
printf '%s\n' "$SUMMARY" > "$RESULT_FILE" 2>/dev/null || true
if [ "$TOTAL" -gt 0 ] && [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS — collection created, points upserted/searched/deleted, zero residue."; exit 0
else echo "RESULT: FAIL (${FAIL} failing)"; exit 1; fi
