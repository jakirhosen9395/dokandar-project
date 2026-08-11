#!/usr/bin/env bash
# DOKANDAR — Elasticsearch contract/smoke test. Tests ANY Elasticsearch server (single node OR cluster).
# Creates a THROWAWAY index `dokandar_estest_<ts>`, exercises mapping/DDL, bulk indexing, bilingual UTF-8,
# search, an aggregation, then DELETES the index and PROVES zero residue. Never touches another index.
#
#   Usage:  bash test.sh [TARGET]
#     TARGET may be: a base URL with creds — bash test.sh "http://elastic:pass@host:9200"
#                    a variant folder      — bash test.sh 03_docker_single   (reads its .env)
#                    an env-file path       — bash test.sh ./03_docker_single/.env
#     Connection sources (highest first): a URL arg / ES_URL → this folder's .env → a per-variant .env →
#     parts (ES_SCHEME/ES_HOST/ES_HTTP_PORT/ES_USER/ELASTIC_PASSWORD; defaults http 127.0.0.1:9200 elastic).
#   Client: uses `curl` (host) or, if absent, a `curlimages/curl` Docker container with --network host.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

_U="${ES_URL:-}"; ARG="${1:-}"; CONNURL=""; ENVF=""
case "$ARG" in
  http://*|https://*) CONNURL="$ARG" ;;
  "")        : ;;
  *.env|*/*) ENVF="$ARG" ;;
  *)         ENVF="$HERE/$ARG/.env" ;;
esac
[ -z "$CONNURL" ] && [ -n "$_U" ] && CONNURL="$_U"
if [ -z "$CONNURL" ]; then
  if [ -n "$ENVF" ]; then
    if   [ -r "$ENVF" ]; then set -a; . "$ENVF"; set +a
    elif [ -f "$ENVF" ]; then echo "  ! env file exists but is NOT READABLE: $ENVF — run as its owner" >&2
    else echo "  ! env file not found: $ENVF (using ES_* env / defaults)" >&2; fi
  elif [ -r "$HERE/.env" ]; then set -a; . "$HERE/.env"; set +a
  else for f in "$HERE"/0*_*/.env /etc/dokandar/.env; do [ -r "$f" ] || continue; set -a; . "$f"; set +a; break; done
  fi
  [ -n "${ES_URL:-}" ] && CONNURL="$ES_URL"
fi

if [ -n "$CONNURL" ]; then
  BASE="$CONNURL"
else
  SCHEME="${ES_SCHEME:-http}"; H="${ES_HOST:-127.0.0.1}"; P="${ES_HTTP_PORT:-9200}"
  U="${ES_USER:-elastic}"; W="${ELASTIC_PASSWORD:-}"
  if [ -n "$W" ]; then BASE="${SCHEME}://${U}:${W}@${H}:${P}"; else BASE="${SCHEME}://${H}:${P}"; fi
fi
BASE="${BASE%/}"
BASE_SAFE="$(printf '%s' "$BASE" | sed -E 's#(https?://[^:/@]+:)[^@]*@#\1****@#')"

# curl runner — host curl, else a curl container (--network host so localhost/remote both reachable)
if command -v curl >/dev/null 2>&1; then
  RUNMODE=host; CURL(){ curl "$@"; }
elif command -v docker >/dev/null 2>&1; then
  RUNMODE=docker; docker image inspect curlimages/curl:latest >/dev/null 2>&1 || docker pull -q curlimages/curl:latest >/dev/null 2>&1 || true
  CURL(){ docker run --rm --network host curlimages/curl:latest "$@"; }
else echo "  ✗ no curl and no docker"; echo "RESULT: FAIL (no client)"; exit 2; fi
# -k tolerates a self-signed cert if the server happens to be https; harmless on http.
cq(){ CURL -s -k --max-time 15 "$@"; }

TS="$(date +%Y%m%d_%H%M%S)_$$"; IDX="dokandar_estest_${TS}"; RESULT_FILE="$HERE/test-result.txt"
PASS=0; FAIL=0
eq(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %-40s [%s]\n' "$1" "$3"
      else FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %-40s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ cq -X DELETE "$BASE/$IDX" >/dev/null 2>&1 || true; }
trap cleanup EXIT
# extract a single JSON scalar via ES filter_path (no jq): returns the last number/string token
val(){ grep -oE '[0-9]+(\.[0-9]+)?|"[^"]*"' | tail -1 | tr -d '"'; }

echo "==> Elasticsearch test   ${BASE_SAFE}   index=${IDX}   [mode=${RUNMODE}]"

# 0. connectivity + AUTH
HEALTH="$(cq "$BASE/_cluster/health?filter_path=status,number_of_nodes" 2>&1)"
ST="$(printf '%s' "$HEALTH" | grep -o '"status":"[^"]*"' | val)"
if [ -z "$ST" ]; then
  printf '  \033[31m✗\033[0m cannot connect / authenticate to %s\n' "$BASE_SAFE"
  printf '     %s\n' "$(printf '%s' "$HEALTH" | head -c 200)"
  echo "RESULT: FAIL (no server / auth)"; exit 1
fi
VER="$(cq "$BASE/?filter_path=version.number" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
NODES="$(printf '%s' "$HEALTH" | grep -o '"number_of_nodes":[0-9]*' | val)"
echo "  server v${VER:-?}  cluster status=${ST}  nodes=${NODES:-?}"
eq "cluster health (green/yellow)" "ok" "$([ "$ST" = green ] || [ "$ST" = yellow ] && echo ok || echo "$ST")"

# 1. create index with an explicit mapping (DDL)
cq -X PUT "$BASE/$IDX" -H 'Content-Type: application/json' -d '{
  "settings":{"number_of_shards":1,"number_of_replicas":0},
  "mappings":{"properties":{"name_bn":{"type":"text"},"name_en":{"type":"keyword"},"qty":{"type":"integer"},"price_minor":{"type":"long"}}}}' >/dev/null 2>&1
eq "create index + mapping" "true" "$(cq "$BASE/$IDX/_mapping?filter_path=*.mappings.properties.qty.type" | grep -q integer && echo true || echo false)"

# 2. bulk index 3 docs (bilingual UTF-8), refresh now
printf '%s\n' \
'{"index":{"_id":"1"}}' '{"name_bn":"চাল","name_en":"rice","qty":100,"price_minor":5500}' \
'{"index":{"_id":"2"}}' '{"name_bn":"ডাল","name_en":"lentil","qty":50,"price_minor":12000}' \
'{"index":{"_id":"3"}}' '{"name_bn":"তেল","name_en":"oil","qty":0,"price_minor":25000}' \
| cq -X POST "$BASE/$IDX/_bulk?refresh=true" -H 'Content-Type: application/x-ndjson' --data-binary @- >/dev/null 2>&1
eq "bulk index 3 documents" "3" "$(cq "$BASE/$IDX/_count?filter_path=count" | val)"

# 3. UTF-8 round-trip
eq "utf-8 bangla round-trip" "চাল" "$(cq "$BASE/$IDX/_doc/1?filter_path=_source.name_bn" | grep -o '"name_bn":"[^"]*"' | val)"

# 4. search (term on keyword)
eq "search term=rice -> 1 hit" "1" "$(cq "$BASE/$IDX/_search?filter_path=hits.total.value" -H 'Content-Type: application/json' -d '{"query":{"term":{"name_en":"rice"}}}' | val)"

# 5. aggregation: sum(qty)
eq "aggregate sum(qty)" "150" "$(cq "$BASE/$IDX/_search?filter_path=aggregations.qsum.value" -H 'Content-Type: application/json' -d '{"size":0,"aggs":{"qsum":{"sum":{"field":"qty"}}}}' | val | sed 's/\.0$//')"

# 6. update by id, refresh, read back
cq -X POST "$BASE/$IDX/_update/3?refresh=true" -H 'Content-Type: application/json' -d '{"doc":{"qty":10}}' >/dev/null 2>&1
eq "update document" "10" "$(cq "$BASE/$IDX/_doc/3?filter_path=_source.qty" | val)"

# 7. delete the index + PROVE zero residue
cleanup
eq "post-clean: index deleted" "false" "$(cq -o /dev/null -w '%{http_code}' "$BASE/$IDX" | grep -q '^200$' && echo true || echo false)"
eq "post-clean: 0 leftover test indices" "0" "$(cq "$BASE/_cat/indices/dokandar_estest_*?h=index" 2>/dev/null | grep -c 'dokandar_estest_')"

TOTAL=$((PASS+FAIL)); STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SUMMARY="Elasticsearch test @ ${STAMP}  ${BASE_SAFE}  v${VER:-?}  mode=${RUNMODE}  ->  ${PASS}/${TOTAL} PASS, ${FAIL} FAIL"
echo ""; echo "=================================================================="
printf '%s\n' "$SUMMARY"; echo "=================================================================="
printf '%s\n' "$SUMMARY" > "$RESULT_FILE" 2>/dev/null || true
if [ "$TOTAL" -gt 0 ] && [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS — test index deleted, zero residue."; exit 0
else echo "RESULT: FAIL (${FAIL} failing)"; exit 1; fi
