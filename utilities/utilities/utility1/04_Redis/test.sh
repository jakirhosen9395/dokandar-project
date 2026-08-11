#!/usr/bin/env bash
# DOKANDAR — Redis contract/smoke test. Tests ANY Redis server/instance (single node OR Redis Cluster).
# Creates a set of THROWAWAY keys under a hash-tagged prefix {dokandar_test_<ts>} (co-located on one slot
# so it works in cluster mode), exercises strings/counters/TTL/list/hash/set/zset + bilingual UTF-8, then
# DELETES them all and PROVES zero residue. Never touches other keys.
#
#   Usage:  bash test.sh [TARGET]
#     TARGET: a redis URL — bash test.sh "redis://default:pass@host:6379"
#             a variant folder — bash test.sh 03_docker_single   (reads its .env)
#             an env-file path  — bash test.sh ./03_docker_single/.env
#     Sources (highest first): a URL arg / REDIS_URL → this folder's .env → a per-variant .env →
#     parts (REDIS_HOST/REDIS_PORT/REDIS_PASSWORD; defaults 127.0.0.1:6379, no password).
#   Client: `redis-cli` (host) or, if absent, a `redis:8` Docker container with --network host.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

_U="${REDIS_URL:-}"; ARG="${1:-}"; CONNURL=""; ENVF=""
case "$ARG" in
  redis://*|rediss://*) CONNURL="$ARG" ;;
  "")        : ;;
  *.env|*/*) ENVF="$ARG" ;;
  *)         ENVF="$HERE/$ARG/.env" ;;
esac
[ -z "$CONNURL" ] && [ -n "$_U" ] && CONNURL="$_U"
if [ -z "$CONNURL" ]; then
  if [ -n "$ENVF" ]; then
    if   [ -r "$ENVF" ]; then set -a; . "$ENVF"; set +a
    elif [ -f "$ENVF" ]; then echo "  ! env file exists but is NOT READABLE: $ENVF" >&2
    else echo "  ! env file not found: $ENVF (using REDIS_* env / defaults)" >&2; fi
  elif [ -r "$HERE/.env" ]; then set -a; . "$HERE/.env"; set +a
  else for f in "$HERE"/0*_*/.env /etc/dokandar/.env; do [ -r "$f" ] || continue; set -a; . "$f"; set +a; break; done
  fi
  [ -n "${REDIS_URL:-}" ] && CONNURL="$REDIS_URL"
fi

# parse redis[s]://[user:pass@]host:port[/db]
H=""; P=""; W=""
if [ -n "$CONNURL" ]; then
  u="${CONNURL#redis://}"; u="${u#rediss://}"; u="${u%%/*}"
  if [ "${u#*@}" != "$u" ]; then creds="${u%@*}"; hp="${u##*@}"; W="${creds#*:}"; else hp="$u"; fi
  H="${hp%%:*}"; [ "${hp#*:}" != "$hp" ] && P="${hp#*:}"
fi
HOST="${H:-${REDIS_HOST:-127.0.0.1}}"; PORT="${P:-${REDIS_PORT:-6379}}"; PASS="${W:-${REDIS_PASSWORD:-}}"
SAFE="redis://${PASS:+default:****@}${HOST}:${PORT}"
REDIS_VERSION="${REDIS_VERSION:-8}"

# runner: host redis-cli, else redis:8 container (--network host). -c = cluster-aware (harmless on single).
IMG="redis:${REDIS_VERSION}"
if command -v redis-cli >/dev/null 2>&1; then RUNMODE=host; RCLI(){ redis-cli "$@"; }
elif command -v docker >/dev/null 2>&1; then
  RUNMODE=docker; docker image inspect "$IMG" >/dev/null 2>&1 || docker pull -q "$IMG" >/dev/null 2>&1 || true
  RCLI(){ docker run --rm --network host "$IMG" redis-cli "$@"; }
else echo "  ✗ no redis-cli and no docker"; echo "RESULT: FAIL (no client)"; exit 2; fi
R(){ RCLI -h "$HOST" -p "$PORT" ${PASS:+-a "$PASS"} --no-auth-warning -c "$@" 2>/dev/null; }

TS="$(date +%Y%m%d_%H%M%S)_$$"; T="{dokandar_test_${TS}}"; RESULT_FILE="$HERE/test-result.txt"
PASS_N=0; FAIL_N=0
eq(){ if [ "$2" = "$3" ]; then PASS_N=$((PASS_N+1)); printf '  \033[32m✓\033[0m %-34s [%s]\n' "$1" "$3"
      else FAIL_N=$((FAIL_N+1)); printf '  \033[31m✗\033[0m %-34s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ R DEL "$T:str" "$T:bn" "$T:ctr" "$T:ttl" "$T:list" "$T:hash" "$T:set" "$T:zset" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Redis test   ${SAFE}   prefix=${T}   [mode=${RUNMODE}]"

# 0. connectivity + AUTH
PONG="$(R ping 2>&1)"
if [ "$PONG" != PONG ]; then
  printf '  \033[31m✗\033[0m cannot connect / authenticate to %s\n' "$SAFE"
  printf '     %s\n' "$(printf '%s' "$PONG" | head -1)"
  echo "RESULT: FAIL (no server / auth)"; exit 1
fi
VER="$(R info server 2>/dev/null | tr -d '\r' | awk -F: '/^redis_version:/{print $2}')"
MODE="$(R info cluster 2>/dev/null | tr -d '\r' | awk -F: '/^cluster_enabled:/{print $2}')"
echo "  server v${VER:-?}  cluster_enabled=${MODE:-0}"
eq "PING -> PONG" "PONG" "$PONG"

# 1. string set/get + bilingual UTF-8
R set "$T:str" "rice" >/dev/null; eq "SET/GET string" "rice" "$(R get "$T:str")"
R set "$T:bn" "চাল" >/dev/null;   eq "utf-8 bangla round-trip" "চাল" "$(R get "$T:bn")"

# 2. counter
R set "$T:ctr" 100 >/dev/null; R incrby "$T:ctr" 50 >/dev/null
eq "INCRBY counter" "150" "$(R get "$T:ctr")"

# 3. TTL / expire
R set "$T:ttl" x >/dev/null; R expire "$T:ttl" 100 >/dev/null
eq "EXPIRE/TTL (>0)" "ok" "$([ "$(R ttl "$T:ttl")" -gt 0 ] 2>/dev/null && echo ok || echo no)"

# 4. list
R rpush "$T:list" a b c >/dev/null; eq "LIST RPUSH/LLEN" "3" "$(R llen "$T:list")"

# 5. hash
R hset "$T:hash" f1 v1 f2 v2 >/dev/null; eq "HASH HSET/HLEN" "2" "$(R hlen "$T:hash")"

# 6. set
R sadd "$T:set" x y z z >/dev/null; eq "SET SADD/SCARD (dedup)" "3" "$(R scard "$T:set")"

# 7. sorted set
R zadd "$T:zset" 1 a 2 b 3 c >/dev/null; eq "ZSET ZADD/ZCARD" "3" "$(R zcard "$T:zset")"

# 8. cleanup + PROVE zero residue (multi-key EXISTS, all co-located via the hash tag)
cleanup
eq "post-clean: 0 test keys" "0" "$(R exists "$T:str" "$T:bn" "$T:ctr" "$T:ttl" "$T:list" "$T:hash" "$T:set" "$T:zset")"

TOTAL=$((PASS_N+FAIL_N)); STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SUMMARY="Redis test @ ${STAMP}  ${SAFE}  v${VER:-?}  mode=${RUNMODE}  ->  ${PASS_N}/${TOTAL} PASS, ${FAIL_N} FAIL"
echo ""; echo "=================================================================="
printf '%s\n' "$SUMMARY"; echo "=================================================================="
printf '%s\n' "$SUMMARY" > "$RESULT_FILE" 2>/dev/null || true
if [ "$TOTAL" -gt 0 ] && [ "$FAIL_N" -eq 0 ]; then echo "RESULT: PASS — test keys deleted, zero residue."; exit 0
else echo "RESULT: FAIL (${FAIL_N} failing)"; exit 1; fi
