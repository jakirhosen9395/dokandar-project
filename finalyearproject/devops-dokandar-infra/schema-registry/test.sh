#!/usr/bin/env bash
# Apicurio contract test — registers a throwaway JSON-schema artifact, fetches it back,
# checks the health endpoint, deletes it, proves zero residue.
#   bash test.sh [docker-single-node-setup]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARG="${1:-}"
case "$ARG" in
  "") for f in "$HERE"/.env "$HERE"/*-setup/.env; do [ -r "$f" ] && { set -a; . "$f"; set +a; break; }; done ;;
  *)  ENVF="$HERE/$ARG/.env"; [ -r "$ENVF" ] && { set -a; . "$ENVF"; set +a; } ;;
esac
HOST="${APICURIO_HOST:-127.0.0.1}"; PORT="${APICURIO_PORT:-8081}"
API="http://${HOST}:${PORT}/apis/registry/v2"

TS="$(date +%s)_$$"; ART="dki-test-${TS}"; RESULT_FILE="$HERE/test-result.txt"; P=0; F=0
eq(){ if [ "$2" = "$3" ]; then P=$((P+1)); printf '  \033[32m✓\033[0m %-36s [%s]\n' "$1" "$3"
     else F=$((F+1)); printf '  \033[31m✗\033[0m %-36s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ curl -s -X DELETE "${API}/groups/default/artifacts/${ART}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Apicurio test  ${HOST}:${PORT}"
eq "health/ready" "ok" "$(curl -s "http://${HOST}:${PORT}/health/ready" | grep -q UP && echo ok || echo no)"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${API}/groups/default/artifacts" \
  -H 'Content-Type: application/json' -H "X-Registry-ArtifactId: ${ART}" -H 'X-Registry-ArtifactType: JSON' \
  -d '{"$schema":"http://json-schema.org/draft-07/schema#","title":"DkiOrder","type":"object","properties":{"ord":{"type":"string"}}}')
eq "register artifact (200)" "200" "$CODE"
eq "fetch artifact back" "DkiOrder" "$(curl -s "${API}/groups/default/artifacts/${ART}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["title"])' 2>/dev/null)"
eq "artifact meta lists version 1" "1" "$(curl -s "${API}/groups/default/artifacts/${ART}/versions" | python3 -c 'import sys,json;print(json.load(sys.stdin)["count"])' 2>/dev/null)"
cleanup
eq "post-clean: zero residue" "404" "$(curl -s -o /dev/null -w '%{http_code}' "${API}/groups/default/artifacts/${ART}")"

TOTAL=$((P+F)); SUMMARY="Apicurio test @ $(date -u +%FT%TZ)  ${HOST}:${PORT}  -> ${P}/${TOTAL} PASS, ${F} FAIL"
echo; echo "$SUMMARY"; echo "$SUMMARY" > "$RESULT_FILE"
[ "$F" -eq 0 ] && { echo "RESULT: PASS — artifact deleted, zero residue."; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
