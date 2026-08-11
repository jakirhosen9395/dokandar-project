#!/usr/bin/env bash
# Redis contract test — throwaway keys under dki_test_<ts>:*, exercises strings/TTL/list/
# hash/incr + UTF-8 + WRONG-PASSWORD rejection, deletes everything, proves zero residue.
#   bash test.sh [docker-single-node-setup | redis://default:pass@host:port]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARG="${1:-}"; H=""; P=""; W=""
case "$ARG" in
  redis://*) u="${ARG#redis://}"; u="${u%%/*}"
             if [ "${u#*@}" != "$u" ]; then W="${u%%@*}"; W="${W#*:}"; u="${u##*@}"; fi
             H="${u%%:*}"; P="${u#*:}" ;;
  "") for f in "$HERE"/.env "$HERE"/*-setup/.env; do [ -r "$f" ] && { set -a; . "$f"; set +a; break; }; done ;;
  *)  ENVF="$HERE/$ARG/.env"; [ -r "$ENVF" ] && { set -a; . "$ENVF"; set +a; } ;;
esac
HOST="${H:-127.0.0.1}"; PORT="${P:-${REDIS_PORT:-6379}}"; PASS="${W:-${REDIS_PASSWORD:-}}"

if command -v redis-cli >/dev/null 2>&1; then MODE=host; R(){ redis-cli -h "$HOST" -p "$PORT" ${PASS:+-a "$PASS"} --no-auth-warning "$@"; }
else CON="$(docker ps --format '{{.Names}}\t{{.Ports}}' | awk -F'\t' -v p=":${PORT}->" 'index($2,p){print $1; exit}')"
     [ -z "$CON" ] && { echo "no redis-cli and no local container on :${PORT}"; echo "RESULT: FAIL"; exit 2; }
     MODE="docker via ${CON}"; R(){ docker exec -i "$CON" redis-cli -h 127.0.0.1 ${PASS:+-a "$PASS"} --no-auth-warning "$@"; }
fi

TS="$(date +%s)_$$"; PFX="dki_test_${TS}"; RESULT_FILE="$HERE/test-result.txt"; PASS_N=0; FAIL_N=0
eq(){ if [ "$2" = "$3" ]; then PASS_N=$((PASS_N+1)); printf '  \033[32m✓\033[0m %-36s [%s]\n' "$1" "$3"
     else FAIL_N=$((FAIL_N+1)); printf '  \033[31m✗\033[0m %-36s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ for k in $(R --scan --pattern "${PFX}:*" 2>/dev/null); do R del "$k" >/dev/null 2>&1; done; }
trap cleanup EXIT

echo "==> Redis test  ${HOST}:${PORT} [mode=${MODE}]"
eq "PING"                   "PONG"  "$(R ping 2>/dev/null)"
[ "$(R ping 2>/dev/null)" != PONG ] && { echo "RESULT: FAIL (no server)"; exit 1; }
eq "SET/GET utf-8"          "চাল"   "$(R set "${PFX}:name" "চাল" >/dev/null; R get "${PFX}:name")"
eq "INCR counter"           "3"     "$(R set "${PFX}:n" 1 >/dev/null; R incrby "${PFX}:n" 2)"
eq "EXPIRE + TTL set"       "1"     "$(R expire "${PFX}:n" 60; true)"
eq "LPUSH/LLEN list"        "2"     "$(R rpush "${PFX}:l" a b >/dev/null; R llen "${PFX}:l")"
eq "HSET/HGET hash"         "50"    "$(R hset "${PFX}:h" qty 50 >/dev/null; R hget "${PFX}:h" qty)"
if [ -n "$PASS" ]; then
  if R_OUT=$(docker run --rm --network host redis:${REDIS_VERSION:-8} redis-cli -h "$HOST" -p "$PORT" -a WRONGPASS --no-auth-warning ping 2>/dev/null) && [ "$R_OUT" = PONG ]; then
    eq "wrong password rejected" "rejected" "accepted"
  else eq "wrong password rejected" "rejected" "rejected"; fi
fi
cleanup
eq "post-clean: zero residue" "0" "$(R --scan --pattern "${PFX}:*" | grep -c . || true)"

TOTAL=$((PASS_N+FAIL_N))
SUMMARY="Redis test @ $(date -u +%FT%TZ)  ${HOST}:${PORT}  -> ${PASS_N}/${TOTAL} PASS, ${FAIL_N} FAIL"
echo; echo "$SUMMARY"; echo "$SUMMARY" > "$RESULT_FILE"
[ "$FAIL_N" -eq 0 ] && { echo "RESULT: PASS — all test keys deleted, zero residue."; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
