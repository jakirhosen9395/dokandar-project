#!/usr/bin/env bash
# DOKANDAR — Temporal contract/smoke test (via the `temporal` CLI). Tests ANY Temporal frontend (dev server
# or a multi-node cluster). Confirms connectivity, then creates a THROWAWAY namespace with a bilingual-UTF-8
# description, reads it back, then DELETES the namespace and PROVES zero residue. Worker-free (it exercises
# the frontend + persistence via namespace CRUD, not a running workflow). Touches nothing else.
#
#   Usage:  bash test.sh [TARGET]
#     TARGET: a variant folder — bash test.sh 03_docker_single   (reads host/port from .env)
#             a host           — bash test.sh 172.31.9.71
#     Resolves TEMPORAL_HOST, TEMPORAL_GRPC_PORT from the TARGET folder's .env, this folder's .env, or env.
#   Client: `temporal` (host) or `temporal` inside a temporalio/admin-tools Docker container (--network host).
#   The Temporal Web UI is the companion temporalio/ui (this test uses the gRPC frontend, not the UI).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

ARG="${1:-}"; ENVF=""
case "$ARG" in
  "")         : ;;
  *.env|*/*)  ENVF="$ARG" ;;
  *[a-zA-Z]*) [ -d "$HERE/$ARG" ] && ENVF="$HERE/$ARG/.env" || TEMPORAL_HOST="$ARG" ;;
  *)          TEMPORAL_HOST="$ARG" ;;
esac
if [ -n "$ENVF" ] && [ -r "$ENVF" ]; then set -a; . "$ENVF"; set +a
elif [ -z "${TEMPORAL_HOST:-}" ] && [ -r "$HERE/.env" ]; then set -a; . "$HERE/.env"; set +a; fi

HOST="${TEMPORAL_HOST:-${HOST_IP:-127.0.0.1}}"; PORT="${TEMPORAL_GRPC_PORT:-7233}"
ADDR="${HOST}:${PORT}"; AT_IMAGE="${TEMPORAL_ADMINTOOLS_IMAGE:-temporalio/admin-tools:latest}"

if command -v temporal >/dev/null 2>&1; then RUNMODE=host; T(){ temporal --address "$ADDR" "$@"; }
elif command -v docker >/dev/null 2>&1; then
  RUNMODE=docker; docker image inspect "$AT_IMAGE" >/dev/null 2>&1 || docker pull -q "$AT_IMAGE" >/dev/null 2>&1 || true
  T(){ docker run --rm --network host "$AT_IMAGE" temporal --address "$ADDR" "$@"; }
else echo "  ✗ no temporal CLI and no docker"; echo "RESULT: FAIL (no client)"; exit 2; fi

TS="$(date +%Y%m%d%H%M%S)$$"; NS="dokandar_test_${TS}"; DESC="চাল-rice ${TS}"; RESULT_FILE="$HERE/test-result.txt"
PASS=0; FAIL=0
eq(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %-32s [%s]\n' "$1" "$3"
      else FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %-32s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ T operator namespace delete "$NS" --yes >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Temporal test   ${ADDR}   namespace=${NS}   [mode=${RUNMODE}]"

# 0. connectivity (frontend reachable — namespace list is a robust up-check)
if ! T operator namespace list >/dev/null 2>&1; then printf '  \033[31m✗\033[0m frontend not reachable at %s\n' "$ADDR"; echo "RESULT: FAIL (no server)"; exit 1; fi
VER="$(T operator cluster system 2>/dev/null | grep -ioE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
echo "  reachable; Temporal server ${VER:-?}"
eq "connectivity (namespace list)" "ok" "ok"

# 1. create a namespace with a bilingual-UTF-8 description (--retention is required, min 24h)
T operator namespace create "$NS" --retention 24h --description "$DESC" >/dev/null 2>&1
# 2. read it back (retry — namespace propagation can take a beat)
got=""; for _ in $(seq 1 10); do got="$(T operator namespace describe "$NS" 2>/dev/null | grep -iE 'Description' | head -1)"; printf '%s' "$got" | grep -q 'চাল-rice' && break; sleep 1; done
eq "create+describe (UTF-8 desc)" "ok" "$(printf '%s' "$got" | grep -q 'চাল-rice' && echo ok || echo no)"
# 3. it appears in the namespace list (-o json so the long name isn't truncated by the table view)
eq "namespace listed" "ok" "$(T operator namespace list -o json 2>/dev/null | grep -q "$NS" && echo ok || echo no)"

# 4. delete + PROVE zero residue (delete is async — poll until the frontend no longer resolves it)
cleanup
gone=no; for _ in $(seq 1 15); do T operator namespace describe "$NS" >/dev/null 2>&1 || { gone=yes; break; }; sleep 2; done
eq "post-clean: namespace gone" "yes" "$gone"

TOTAL=$((PASS+FAIL)); STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SUMMARY="Temporal test @ ${STAMP}  ${ADDR}  v${VER:-?}  mode=${RUNMODE}  ->  ${PASS}/${TOTAL} PASS, ${FAIL} FAIL"
echo ""; echo "=================================================================="
printf '%s\n' "$SUMMARY"; echo "=================================================================="
printf '%s\n' "$SUMMARY" > "$RESULT_FILE" 2>/dev/null || true
if [ "$TOTAL" -gt 0 ] && [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS — namespace created/described/deleted, zero residue."; exit 0
else echo "RESULT: FAIL (${FAIL} failing)"; exit 1; fi
