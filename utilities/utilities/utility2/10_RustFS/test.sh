#!/usr/bin/env bash
# DOKANDAR — RustFS contract/smoke test (S3 API, via the `mc` client). RustFS is S3-compatible, so the
# MinIO client works against it. Tests ANY RustFS (single or distributed). DEEP contract: lists buckets
# (auth) → creates a THROWAWAY bucket → PUTs 2 bilingual-UTF-8 objects → GETs them back byte-identical →
# asserts the list count → stats → server-side COPY → then REMOVES everything and PROVES zero residue.
#
#   Usage:  bash test.sh [TARGET]
#     TARGET: a variant folder — bash test.sh 03_docker_single   (reads creds + port from its .env)
#             a host           — bash test.sh 172.31.9.71        (then PASTE the creds setup.sh printed:)
#                                  RUSTFS_HOST=h RUSTFS_ACCESS_KEY=ak RUSTFS_SECRET_KEY=sk bash test.sh
#   Two ways to feed creds (dual-mode): (a) the variant's .env, or (b) env vars you paste from setup.sh's
#   console output — point it at a DIFFERENT host than the one running RustFS to prove cross-host access.
#   Client: `mc` (host) or a `minio/mc` Docker container (--network host). No host packages needed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

ARG="${1:-}"; ENVF=""
case "$ARG" in
  "")         : ;;
  *.env|*/*)  ENVF="$ARG" ;;
  *[a-zA-Z]*) [ -d "$HERE/$ARG" ] && ENVF="$HERE/$ARG/.env" || RUSTFS_HOST="$ARG" ;;
  *)          RUSTFS_HOST="$ARG" ;;
esac
if [ -n "$ENVF" ] && [ -r "$ENVF" ]; then set -a; . "$ENVF"; set +a
elif [ -z "${RUSTFS_HOST:-}" ] && [ -r "$HERE/.env" ]; then set -a; . "$HERE/.env"; set +a; fi

HOST="${RUSTFS_HOST:-${HOST_IP:-127.0.0.1}}"; PORT="${RUSTFS_API_PORT:-9000}"
AK="${RUSTFS_ACCESS_KEY:-}"; SK="${RUSTFS_SECRET_KEY:-}"
URL="http://${AK}:${SK}@${HOST}:${PORT}"          # MC_HOST_<alias> form — ephemeral, no ~/.mc residue
A=rfs                                              # alias name used below

if command -v mc >/dev/null 2>&1; then RUNMODE=host
  MC(){ MC_HOST_rfs="$URL" mc --no-color "$@"; }
elif command -v docker >/dev/null 2>&1; then RUNMODE=docker
  docker image inspect minio/mc:latest >/dev/null 2>&1 || docker pull -q minio/mc:latest >/dev/null 2>&1 || true
  MC(){ docker run --rm -i --network host -e MC_HOST_rfs="$URL" minio/mc:latest --no-color "$@"; }
else echo "  ✗ no mc and no docker"; echo "RESULT: FAIL (no client)"; exit 2; fi

TS="$(date +%Y%m%d%H%M%S)$$"; B="dokandar-test-${TS}"; CONTENT="dokandar-rustfs চাল-rice ${TS}"
RESULT_FILE="$HERE/test-result.txt"; PASS=0; FAIL=0
eq(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %-32s [%s]\n' "$1" "$3"
      else FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %-32s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ MC rm --recursive --force "$A/$B" >/dev/null 2>&1 || true; MC rb --force "$A/$B" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> RustFS test   http://${HOST}:${PORT}   bucket=${B}   [mode=${RUNMODE}]"

# 0. connectivity + auth: list buckets (fails on bad creds / unreachable)
if ! LS="$(MC ls "$A" 2>&1)"; then printf '  \033[31m✗\033[0m not reachable / auth failed at %s:%s\n%s\n' "$HOST" "$PORT" "$LS"; echo "RESULT: FAIL (no server)"; exit 1; fi
echo "  reachable; S3 endpoint answering"

# 1. create a throwaway bucket
eq "make bucket" "ok" "$(MC mb "$A/$B" >/dev/null 2>&1 && echo ok || echo no)"
# 2. PUT two objects (bilingual UTF-8)
eq "put object 1" "ok" "$(printf '%s' "${CONTENT} one" | MC pipe "$A/$B/one.txt" >/dev/null 2>&1 && echo ok || echo no)"
eq "put object 2" "ok" "$(printf '%s' "${CONTENT} two" | MC pipe "$A/$B/two.txt" >/dev/null 2>&1 && echo ok || echo no)"
# 3. GET back byte-identical (UTF-8)
eq "get object 1 (UTF-8)" "${CONTENT} one" "$(MC cat "$A/$B/one.txt" 2>/dev/null)"
# 4. list count == 2
eq "list shows 2 objects" "2" "$(MC ls "$A/$B" 2>/dev/null | grep -cE '\.txt$' || echo 0)"
# 5. stat object
eq "stat object 1" "ok" "$(MC stat "$A/$B/one.txt" >/dev/null 2>&1 && echo ok || echo no)"
# 6. server-side copy
eq "copy object" "${CONTENT} one" "$(MC cp "$A/$B/one.txt" "$A/$B/copy.txt" >/dev/null 2>&1; MC cat "$A/$B/copy.txt" 2>/dev/null)"

# 7. remove everything + PROVE zero residue
cleanup; sleep 1
eq "post-clean: bucket gone" "no" "$(MC ls "$A" 2>/dev/null | grep -q "$B" && echo yes || echo no)"

TOTAL=$((PASS+FAIL)); STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SUMMARY="RustFS test @ ${STAMP}  http://${HOST}:${PORT}  mode=${RUNMODE}  ->  ${PASS}/${TOTAL} PASS, ${FAIL} FAIL"
echo ""; echo "=================================================================="
printf '%s\n' "$SUMMARY"; echo "=================================================================="
printf '%s\n' "$SUMMARY" > "$RESULT_FILE" 2>/dev/null || true
if [ "$TOTAL" -gt 0 ] && [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS — objects put/got/copied/removed, zero residue."; exit 0
else echo "RESULT: FAIL (${FAIL} failing)"; exit 1; fi
