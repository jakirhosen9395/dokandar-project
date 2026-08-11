#!/usr/bin/env bash
# RustFS contract test (S3 API via the MinIO `mc` client — RustFS is S3-compatible):
# throwaway bucket -> PUT 2 UTF-8 objects -> GET byte-identical -> list count -> remove all
# -> prove zero residue. Client: host `mc` or minio/mc docker (--network host).
#   bash test.sh [docker-single-node-setup]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARG="${1:-}"
case "$ARG" in
  "") for f in "$HERE"/.env "$HERE"/*-setup/.env; do [ -r "$f" ] && { set -a; . "$f"; set +a; break; }; done ;;
  *)  ENVF="$HERE/$ARG/.env"; [ -r "$ENVF" ] && { set -a; . "$ENVF"; set +a; } ;;
esac
HOST="${RUSTFS_HOST:-127.0.0.1}"; PORT="${RUSTFS_API_PORT:-9000}"
AK="${RUSTFS_ACCESS_KEY:-dki}"; SK="${RUSTFS_SECRET_KEY:-}"
URL="http://${AK}:${SK}@${HOST}:${PORT}"
if command -v mc >/dev/null 2>&1; then MODE=host; MC(){ MC_HOST_rfs="$URL" mc --no-color "$@"; }
elif command -v docker >/dev/null 2>&1; then MODE=docker
  docker image inspect minio/mc:latest >/dev/null 2>&1 || docker pull -q minio/mc:latest >/dev/null 2>&1 || true
  MC(){ docker run --rm -i --network host -e MC_HOST_rfs="$URL" minio/mc:latest --no-color "$@"; }
else echo "no mc and no docker"; echo "RESULT: FAIL"; exit 2; fi

TS="$(date +%s)$$"; B="dki-test-${TS}"; RESULT_FILE="$HERE/test-result.txt"; P=0; F=0
eq(){ if [ "$2" = "$3" ]; then P=$((P+1)); printf '  \033[32m✓\033[0m %-36s [%s]\n' "$1" "$3"
     else F=$((F+1)); printf '  \033[31m✗\033[0m %-36s expected[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
cleanup(){ MC rb --force "rfs/${B}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> RustFS test  ${HOST}:${PORT} [mode=${MODE}]"
eq "health endpoint" "ok" "$(curl -fs "http://${HOST}:${PORT}/health" >/dev/null 2>&1 && echo ok || echo no)"
eq "make bucket" "ok" "$(MC mb "rfs/${B}" >/dev/null 2>&1 && echo ok || echo no)"
CONTENT="dki-rustfs চাল-rice ${TS}"
eq "put object (mc pipe)" "ok" "$(printf '%s' "$CONTENT" | MC pipe "rfs/${B}/rice.txt" >/dev/null 2>&1 && echo ok || echo no)"
eq "get object byte-identical" "ok" "$([ "$(MC cat "rfs/${B}/rice.txt" 2>/dev/null)" = "$CONTENT" ] && echo ok || echo no)"
eq "list shows 1 object" "1" "$(MC ls "rfs/${B}" 2>/dev/null | grep -c .)"
cleanup
eq "post-clean: zero residue" "0" "$(MC ls rfs/ 2>/dev/null | grep -c "dki-test-")"

TOTAL=$((P+F)); SUMMARY="RustFS test @ $(date -u +%FT%TZ)  ${HOST}:${PORT}  -> ${P}/${TOTAL} PASS, ${F} FAIL"
echo; echo "$SUMMARY"; echo "$SUMMARY" > "$RESULT_FILE"
[ "$F" -eq 0 ] && { echo "RESULT: PASS — bucket removed, zero residue."; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
