#!/usr/bin/env bash
# MongoDB contract test — throwaway db dki_mongotest_<ts>: insert/find/update/index/UTF-8 +
# wrong-password rejection; drops the db and proves zero residue.
#   bash test.sh [docker-single-node-setup]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARG="${1:-}"
case "$ARG" in
  "") for f in "$HERE"/.env "$HERE"/*-setup/.env; do [ -r "$f" ] && { set -a; . "$f"; set +a; break; }; done ;;
  *)  ENVF="$HERE/$ARG/.env"; [ -r "$ENVF" ] && { set -a; . "$ENVF"; set +a; } ;;
esac
HOST="${MONGO_HOST:-127.0.0.1}"; PORT="${MONGO_PORT:-27017}"
USER_="${MONGO_ROOT_USER:-dki}"; PASS_="${MONGO_ROOT_PASSWORD:-}"

CON="$(docker ps --format '{{.Names}}\t{{.Ports}}' | awk -F'\t' -v p=":${PORT}->" 'index($2,p){print $1; exit}')"
if command -v mongosh >/dev/null 2>&1; then MODE=host
  M(){ mongosh --quiet "mongodb://${USER_}:${PASS_}@${HOST}:${PORT}/?authSource=admin" --eval "$1"; }
elif [ -n "$CON" ]; then MODE="docker via ${CON}"
  M(){ docker exec -i "$CON" mongosh --quiet -u "$USER_" -p "$PASS_" --authenticationDatabase admin --eval "$1"; }
else echo "no mongosh and no local container on :${PORT}"; echo "RESULT: FAIL"; exit 2; fi

TS="$(date +%s)_$$"; DB="dki_mongotest_${TS}"; RESULT_FILE="$HERE/test-result.txt"; P=0; F=0
eq(){ if [ "$2" = "$3" ]; then P=$((P+1)); printf '  \033[32m✓\033[0m %-36s [%s]\n' "$1" "$3"
     else F=$((F+1)); printf '  \033[31m✗\033[0m %-36s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ M "db.getSiblingDB('${DB}').dropDatabase()" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> MongoDB test  ${HOST}:${PORT} user=${USER_} [mode=${MODE}]"
eq "ping"                 "1"    "$(M 'db.runCommand({ping:1}).ok' 2>/dev/null)"
[ "$(M 'db.runCommand({ping:1}).ok' 2>/dev/null)" != 1 ] && { echo "RESULT: FAIL (no server)"; exit 1; }
eq "insertMany 3 docs"    "3"    "$(M "db.getSiblingDB('${DB}').items.insertMany([{n:'rice',bn:'চাল',q:100},{n:'lentil',bn:'ডাল',q:50},{n:'oil',bn:'তেল',q:0}]).insertedIds ? 3 : 0")"
eq "find by field"        "চাল"  "$(M "db.getSiblingDB('${DB}').items.findOne({n:'rice'}).bn")"
eq "updateOne \$inc"      "60"   "$(M "db.getSiblingDB('${DB}').items.updateOne({n:'lentil'},{\$inc:{q:10}}); db.getSiblingDB('${DB}').items.findOne({n:'lentil'}).q")"
eq "aggregate sum"        "160"  "$(M "db.getSiblingDB('${DB}').items.aggregate([{\$group:{_id:null,s:{\$sum:'\$q'}}}]).toArray()[0].s")"
eq "createIndex"          "n_1"  "$(M "db.getSiblingDB('${DB}').items.createIndex({n:1})")"
if docker run --rm --network host mongo:${MONGO_VERSION:-8} mongosh --quiet "mongodb://${USER_}:WRONG@${HOST}:${PORT}/?authSource=admin" --eval 'db.runCommand({ping:1})' >/dev/null 2>&1; then
  eq "wrong password rejected" "rejected" "accepted"
else eq "wrong password rejected" "rejected" "rejected"; fi
cleanup
eq "post-clean: zero residue" "0" "$(M "db.adminCommand('listDatabases').databases.filter(d=>d.name.startsWith('dki_mongotest_')).length")"

TOTAL=$((P+F)); SUMMARY="MongoDB test @ $(date -u +%FT%TZ)  ${HOST}:${PORT}  -> ${P}/${TOTAL} PASS, ${F} FAIL"
echo; echo "$SUMMARY"; echo "$SUMMARY" > "$RESULT_FILE"
[ "$F" -eq 0 ] && { echo "RESULT: PASS — test database dropped, zero residue."; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
