#!/usr/bin/env bash
# DOKANDAR — NATS JetStream contract/smoke test (via the `nats` CLI). Tests ANY NATS (single node or a
# JetStream cluster member). Confirms connectivity + JetStream, then creates a THROWAWAY KV bucket, puts a
# bilingual-UTF-8 value, reads it back, then deletes the key + bucket and PROVES zero residue. Nothing else.
#
#   Usage:  bash test.sh [TARGET]
#     TARGET: a variant folder — bash test.sh 03_docker_single   (reads host/port/token from .env)
#             a host           — bash test.sh 172.31.9.71        (then pass the token via env)
#     Resolves NATS_HOST, NATS_CLIENT_PORT, NATS_AUTH_TOKEN from the TARGET folder's .env, this folder's
#     .env, or the environment.
#   Client: `nats` (host) or `nats` inside a natsio/nats-box Docker container (--network host). NATS has no
#   browser UI (:8222 serves JSON monitoring only).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

ARG="${1:-}"; ENVF=""
case "$ARG" in
  "")         : ;;
  *.env|*/*)  ENVF="$ARG" ;;
  *[a-zA-Z]*) [ -d "$HERE/$ARG" ] && ENVF="$HERE/$ARG/.env" || NATS_HOST="$ARG" ;;
  *)          NATS_HOST="$ARG" ;;
esac
if [ -n "$ENVF" ] && [ -r "$ENVF" ]; then set -a; . "$ENVF"; set +a
elif [ -z "${NATS_HOST:-}" ] && [ -r "$HERE/.env" ]; then set -a; . "$HERE/.env"; set +a; fi

HOST="${NATS_HOST:-${HOST_IP:-127.0.0.1}}"; PORT="${NATS_CLIENT_PORT:-4222}"
TOKEN="${NATS_AUTH_TOKEN:-}"
if [ -n "$TOKEN" ]; then URL="nats://${TOKEN}@${HOST}:${PORT}"; else URL="nats://${HOST}:${PORT}"; fi
NB_IMAGE="${NATS_BOX_IMAGE:-natsio/nats-box:latest}"

if command -v nats >/dev/null 2>&1; then RUNMODE=host; NATS(){ nats -s "$URL" "$@"; }
elif command -v docker >/dev/null 2>&1; then
  RUNMODE=docker; docker image inspect "$NB_IMAGE" >/dev/null 2>&1 || docker pull -q "$NB_IMAGE" >/dev/null 2>&1 || true
  NATS(){ docker run --rm --network host "$NB_IMAGE" nats -s "$URL" "$@"; }
else echo "  ✗ no nats CLI and no docker"; echo "RESULT: FAIL (no client)"; exit 2; fi

TS="$(date +%Y%m%d%H%M%S)$$"; B="DOKTEST_${TS}"; K="rice"; V="চাল-rice ${TS}"; RESULT_FILE="$HERE/test-result.txt"
PASS=0; FAIL=0
eq(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %-32s [%s]\n' "$1" "$3"
      else FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %-32s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ NATS kv del "$B" "$K" -f >/dev/null 2>&1 || true; NATS kv rm "$B" -f >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> NATS test   nats://${HOST}:${PORT}   bucket=${B}   [mode=${RUNMODE}]"

# 0. connectivity + JetStream
INFO="$(NATS account info 2>&1)"
if ! printf '%s' "$INFO" | grep -qiE 'JetStream|Memory|Streams'; then printf '  \033[31m✗\033[0m not reachable / JetStream off at %s\n%s\n' "nats://${HOST}:${PORT}" "$(printf '%s' "$INFO" | head -2)"; echo "RESULT: FAIL (no server)"; exit 1; fi
echo "  reachable; JetStream account responding"
eq "connectivity + JetStream" "ok" "$(printf '%s' "$INFO" | grep -qiE 'JetStream|Streams' && echo ok || echo no)"

# 1. create a KV bucket — TOPOLOGY-AWARE: on a JetStream CLUSTER use R3 (RAFT-replicated across all three
#    nodes, so this actually exercises the cluster); on a single node R3 is rejected, so fall back to R1.
R=3; NATS kv add "$B" --replicas=3 --history=1 >/dev/null 2>&1 || { R=1; NATS kv add "$B" --replicas=1 --history=1 >/dev/null 2>&1; }
eq "create KV bucket (R${R})" "ok" "$(NATS kv ls 2>/dev/null | grep -q "$B" && echo ok || echo no)"
# on a cluster, PROVE the bucket is RAFT-replicated across 3 nodes by reading the KV's backing JetStream
# stream config (KV_<bucket>.config.num_replicas == 3) — a reliable JSON field, not scraped table text.
[ "$R" = 3 ] && eq "cluster: bucket replicated x3" "3" "$(NATS stream info "KV_$B" --json 2>/dev/null | grep -oE '"num_replicas": *[0-9]+' | head -1 | grep -oE '[0-9]+')"
# 2. put a bilingual-UTF-8 value
eq "put key"          "ok" "$(NATS kv put "$B" "$K" "$V" >/dev/null 2>&1 && echo ok || echo no)"
# 3. get it back, byte-identical
eq "get key (UTF-8)"  "$V" "$(NATS kv get "$B" "$K" --raw 2>/dev/null | tr -d '\r\n')"

# 4. delete key + bucket, PROVE zero residue
cleanup; sleep 1
eq "post-clean: bucket gone" "no" "$(NATS kv ls 2>/dev/null | grep -q "$B" && echo yes || echo no)"

TOTAL=$((PASS+FAIL)); STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SUMMARY="NATS test @ ${STAMP}  nats://${HOST}:${PORT}  mode=${RUNMODE}  ->  ${PASS}/${TOTAL} PASS, ${FAIL} FAIL"
echo ""; echo "=================================================================="
printf '%s\n' "$SUMMARY"; echo "=================================================================="
printf '%s\n' "$SUMMARY" > "$RESULT_FILE" 2>/dev/null || true
if [ "$TOTAL" -gt 0 ] && [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS — KV bucket created, value put/got/deleted, zero residue."; exit 0
else echo "RESULT: FAIL (${FAIL} failing)"; exit 1; fi
