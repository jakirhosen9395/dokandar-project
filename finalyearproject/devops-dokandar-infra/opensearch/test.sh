#!/usr/bin/env bash
# OpenSearch contract test — via REST: throwaway index dki-test-<ts>, index 3 docs (UTF-8),
# refresh, full-text search + aggregation, delete the index, prove zero residue.
#   bash test.sh [docker-single-node-setup]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARG="${1:-}"
case "$ARG" in
  "") for f in "$HERE"/.env "$HERE"/*-setup/.env; do [ -r "$f" ] && { set -a; . "$f"; set +a; break; }; done ;;
  *)  ENVF="$HERE/$ARG/.env"; [ -r "$ENVF" ] && { set -a; . "$ENVF"; set +a; } ;;
esac
HOST="${OPENSEARCH_HOST:-127.0.0.1}"; PORT="${OPENSEARCH_PORT:-9201}"; BASE="http://${HOST}:${PORT}"
J(){ curl -s -H 'Content-Type: application/json' "$@"; }

TS="$(date +%s)_$$"; IDX="dki-test-${TS}"; RESULT_FILE="$HERE/test-result.txt"; P=0; F=0
eq(){ if [ "$2" = "$3" ]; then P=$((P+1)); printf '  \033[32m✓\033[0m %-36s [%s]\n' "$1" "$3"
     else F=$((F+1)); printf '  \033[31m✗\033[0m %-36s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ J -X DELETE "${BASE}/${IDX}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> OpenSearch test  ${BASE}"
VER="$(J "${BASE}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["version"]["number"])' 2>/dev/null)"
eq "connect + version (${VER:-none})" "ok" "$([ -n "$VER" ] && echo ok || echo no)"
[ -z "$VER" ] && { echo "RESULT: FAIL (no server)"; exit 1; }
J -X PUT "${BASE}/${IDX}" -d '{"settings":{"number_of_shards":1,"number_of_replicas":0}}' >/dev/null 2>&1
eq "create index" "true" "$(J "${BASE}/${IDX}" | grep -q "\"${IDX}\"" && echo true)"
J -X POST "${BASE}/${IDX}/_doc/1" -d '{"name_en":"rice","name_bn":"চাল","qty":100}' >/dev/null 2>&1
J -X POST "${BASE}/${IDX}/_doc/2" -d '{"name_en":"lentil","name_bn":"ডাল","qty":50}' >/dev/null 2>&1
J -X POST "${BASE}/${IDX}/_doc/3" -d '{"name_en":"oil","name_bn":"তেল","qty":0}' >/dev/null 2>&1
J -X POST "${BASE}/${IDX}/_refresh" >/dev/null 2>&1
eq "index 3 docs" "3" "$(J "${BASE}/${IDX}/_count" | python3 -c 'import sys,json;print(json.load(sys.stdin)["count"])' 2>/dev/null)"
eq "full-text search 'rice'" "1" "$(J "${BASE}/${IDX}/_search?q=name_en:rice" | python3 -c 'import sys,json;print(json.load(sys.stdin)["hits"]["total"]["value"])' 2>/dev/null)"
eq "aggregation sum(qty)" "150" "$(J "${BASE}/${IDX}/_search" -d '{"size":0,"aggs":{"s":{"sum":{"field":"qty"}}}}' | python3 -c 'import sys,json;print(int(json.load(sys.stdin)["aggregations"]["s"]["value"]))' 2>/dev/null)"
eq "utf-8 bangla round-trip" "চাল" "$(J "${BASE}/${IDX}/_doc/1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["_source"]["name_bn"])' 2>/dev/null)"
cleanup
eq "post-clean: zero residue" "0" "$(J "${BASE}/_cat/indices/dki-test-*?h=index" 2>/dev/null | grep -c .)"

TOTAL=$((P+F)); SUMMARY="OpenSearch test @ $(date -u +%FT%TZ)  ${BASE}  v${VER}  -> ${P}/${TOTAL} PASS, ${F} FAIL"
echo; echo "$SUMMARY"; echo "$SUMMARY" > "$RESULT_FILE"
[ "$F" -eq 0 ] && { echo "RESULT: PASS — test index deleted, zero residue."; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
