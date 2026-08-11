#!/usr/bin/env bash
# DOKANDAR — OpenBao contract/smoke test (HTTP API, via curl). Tests ANY OpenBao (single or Raft cluster).
# Confirms the server is initialised + unsealed, writes a THROWAWAY KV v2 secret (bilingual UTF-8), reads
# it back, then DESTROYS it and PROVES zero residue (404). Never touches another path.
#
#   Usage:  bash test.sh [TARGET]
#     TARGET: a variant folder — bash test.sh 03_docker_single   (reads BAO_ROOT_TOKEN + port from .env)
#             a host           — bash test.sh 172.31.9.71        (then pass BAO_TOKEN via env)
#     Resolves: BAO_HOST, BAO_API_PORT, and a token (BAO_TOKEN or BAO_ROOT_TOKEN) from the TARGET folder's
#     .env, this folder's .env, or the environment.
#   Client: curl (host) or a curlimages/curl Docker container (--network host).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

ARG="${1:-}"; ENVF=""
case "$ARG" in
  "")        : ;;
  *.env|*/*) ENVF="$ARG" ;;
  *[a-zA-Z]*) [ -d "$HERE/$ARG" ] && ENVF="$HERE/$ARG/.env" || BAO_HOST="$ARG" ;;
  *)         BAO_HOST="$ARG" ;;
esac
if [ -n "$ENVF" ] && [ -r "$ENVF" ]; then set -a; . "$ENVF"; set +a
elif [ -z "${BAO_HOST:-}" ] && [ -r "$HERE/.env" ]; then set -a; . "$HERE/.env"; set +a; fi

HOST="${BAO_HOST:-${HOST_IP:-127.0.0.1}}"; PORT="${BAO_API_PORT:-8200}"
TOKEN="${BAO_TOKEN:-${BAO_ROOT_TOKEN:-}}"; BASE="http://${HOST}:${PORT}"

if command -v curl >/dev/null 2>&1; then RUNMODE=host; CURL(){ curl "$@"; }
elif command -v docker >/dev/null 2>&1; then
  RUNMODE=docker; docker image inspect curlimages/curl:latest >/dev/null 2>&1 || docker pull -q curlimages/curl:latest >/dev/null 2>&1 || true
  CURL(){ docker run --rm --network host curlimages/curl:latest "$@"; }
else echo "  ✗ no curl and no docker"; echo "RESULT: FAIL (no client)"; exit 2; fi
cq(){ CURL -s --max-time 15 "$@"; }
api(){ cq -H "X-Vault-Token: ${TOKEN}" "$@"; }

TS="$(date +%Y%m%d_%H%M%S)_$$"; P="dokandar_test_${TS}"; RESULT_FILE="$HERE/test-result.txt"
PASS=0; FAIL=0
eq(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %-34s [%s]\n' "$1" "$3"
      else FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %-34s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ api -X DELETE "$BASE/v1/secret/metadata/${P}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> OpenBao test   ${BASE}   path=secret/${P}   [mode=${RUNMODE}]"

# 0. health: initialised + unsealed
H="$(cq "$BASE/v1/sys/health?uninitcode=200&sealedcode=200&standbycode=200" 2>&1)"
INIT="$(printf '%s' "$H" | grep -oE '"initialized":(true|false)' | head -1 | cut -d: -f2)"
SEALED="$(printf '%s' "$H" | grep -oE '"sealed":(true|false)' | head -1 | cut -d: -f2)"
if [ -z "$INIT" ]; then printf '  \033[31m✗\033[0m not reachable at %s\n' "$BASE"; echo "RESULT: FAIL (no server)"; exit 1; fi
VER="$(printf '%s' "$H" | grep -oE '"version":"[^"]*"' | head -1 | cut -d'"' -f4)"
echo "  version v${VER:-?}  initialized=${INIT}  sealed=${SEALED}"
eq "initialized" "true" "$INIT"
eq "unsealed"    "false" "$SEALED"

if [ -z "$TOKEN" ]; then printf '  \033[31m✗\033[0m no token (set BAO_TOKEN / BAO_ROOT_TOKEN)\n'; echo "RESULT: FAIL (no token)"; exit 1; fi

# 1. write a KV v2 secret (bilingual UTF-8)
api -X POST "$BASE/v1/secret/data/${P}" -H 'content-type: application/json' -d '{"data":{"name":"চাল-rice","qty":"100"}}' >/dev/null 2>&1
# 2. read it back
R="$(api "$BASE/v1/secret/data/${P}" 2>/dev/null)"
eq "write+read secret" "চাল-rice" "$(printf '%s' "$R" | grep -oE '"name":"[^"]*"' | head -1 | cut -d'"' -f4)"
eq "secret field qty"  "100"      "$(printf '%s' "$R" | grep -oE '"qty":"[^"]*"' | head -1 | cut -d'"' -f4)"

# 3. list shows it
eq "list shows the key" "ok" "$(api -X LIST "$BASE/v1/secret/metadata" 2>/dev/null | grep -q "${P}" && echo ok || echo no)"

# 4. destroy + PROVE zero residue (read -> 404)
cleanup; sleep 1
eq "post-clean: secret gone (404)" "404" "$(api -o /dev/null -w '%{http_code}' "$BASE/v1/secret/data/${P}" 2>/dev/null)"

TOTAL=$((PASS+FAIL)); STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SUMMARY="OpenBao test @ ${STAMP}  ${BASE}  v${VER:-?}  mode=${RUNMODE}  ->  ${PASS}/${TOTAL} PASS, ${FAIL} FAIL"
echo ""; echo "=================================================================="
printf '%s\n' "$SUMMARY"; echo "=================================================================="
printf '%s\n' "$SUMMARY" > "$RESULT_FILE" 2>/dev/null || true
if [ "$TOTAL" -gt 0 ] && [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS — secret written/read/destroyed, zero residue."; exit 0
else echo "RESULT: FAIL (${FAIL} failing)"; exit 1; fi
