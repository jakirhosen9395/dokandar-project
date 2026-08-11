#!/usr/bin/env bash
# DOKANDAR utility — RustFS · Docker Compose single-node · lifecycle wrapper.
# Auto-generates the S3 access key (20 hex) + secret key (40 hex), brings the container up, verifies the
# keys over the S3 API. Objects + logs are HOST bind mounts (${DATA_ROOT}/rustfs_docker) and SURVIVE
# `docker compose down -v`.  Usage:
#   bash setup.sh up [--gen-keys|--access KEY|--secret KEY] | down | purge | status | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${RUSTFS_API_PORT:=9000}"; : "${RUSTFS_CONSOLE_PORT:=9001}"
: "${RUSTFS_IMAGE:=rustfs/rustfs:1.0.0-beta.8}"
DATA_DIR="${DATA_ROOT}/rustfs_docker"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up [--gen-keys|--access KEY|--secret KEY] | down | purge | status | logs"; }
genhex(){ local s; s="$(od -An -tx1 -N40 /dev/urandom | tr -dc 'a-f0-9')"; printf '%s' "${s:0:${1:-40}}"; }  # SIGPIPE-safe
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true; export "${k}=${v}"
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }
# S3 verify via the minio/mc client (RustFS is S3-compatible). Args: mc subcommand...
MC(){ docker run --rm -i --network host -e MC_HOST_rfs="http://${RUSTFS_ACCESS_KEY}:${RUSTFS_SECRET_KEY}@127.0.0.1:${RUSTFS_API_PORT}" minio/mc:latest --no-color "$@"; }

GEN=0; CLI_AK=""; CLI_SK=""

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (keys shown ONCE — copy them into your test env)"
  printf '%s' "$(_c '1;36')"; echo "============ RustFS (Docker) — connection details ============"; printf '%s' "$(_c 0)"
  cat <<SUM
  S3 endpoint    : http://${host}:${RUSTFS_API_PORT}
  Access key     : ${RUSTFS_ACCESS_KEY}
  Secret key     : ${RUSTFS_SECRET_KEY}
  Console UI     : http://${host}:${RUSTFS_CONSOLE_PORT}   (browser — log in with the keys above)
  aws s3 example : aws --endpoint-url http://${host}:${RUSTFS_API_PORT} s3 ls
  Test from afar : RUSTFS_HOST=${host} RUSTFS_API_PORT=${RUSTFS_API_PORT} RUSTFS_ACCESS_KEY=${RUSTFS_ACCESS_KEY} RUSTFS_SECRET_KEY=${RUSTFS_SECRET_KEY} bash ../test.sh
  Data (host)    : ${DATA_DIR}/data (objects), ${DATA_DIR}/logs   (bind mounts — survive 'down -v')
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "============================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  step "1/3  Resolve S3 keys + bind-mount data dirs"
  [ -n "$CLI_AK" ] && RUSTFS_ACCESS_KEY="$CLI_AK"
  [ -n "$CLI_SK" ] && RUSTFS_SECRET_KEY="$CLI_SK"
  if [ "$GEN" = 1 ] || [ -z "${RUSTFS_ACCESS_KEY:-}" ]; then RUSTFS_ACCESS_KEY="$(genhex 20)"; ok "access key: generated (20 hex)"; else ok "access key: reused"; fi
  if [ "$GEN" = 1 ] || [ -z "${RUSTFS_SECRET_KEY:-}" ]; then RUSTFS_SECRET_KEY="$(genhex 40)"; ok "secret key: generated (40 hex)"; else ok "secret key: reused"; fi
  set_env_var RUSTFS_ACCESS_KEY "$RUSTFS_ACCESS_KEY"; set_env_var RUSTFS_SECRET_KEY "$RUSTFS_SECRET_KEY"
  set_env_var RUSTFS_API_PORT "$RUSTFS_API_PORT"; set_env_var RUSTFS_CONSOLE_PORT "$RUSTFS_CONSOLE_PORT"
  sudo mkdir -p "$DATA_DIR/data" "$DATA_DIR/logs"; sudo chown -R 10001:10001 "$DATA_DIR" 2>/dev/null || true; sudo chmod -R 755 "$DATA_DIR" 2>/dev/null || true

  step "2/3  docker compose up -d"
  docker compose up -d
  printf '   waiting for the S3 API'; local h=000
  for _ in $(seq 1 30); do h="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${RUSTFS_API_PORT}/health" 2>/dev/null || echo 000)"; [ "$h" = 200 ] && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  [ "$h" = 200 ] && ok "S3 API live on :${RUSTFS_API_PORT} (/health)" || warn "API not answering yet"

  step "3/3  Verify S3 credentials (mc ls)"
  MC ls rfs >/dev/null 2>&1 && ok "S3 keys valid — ListBuckets OK" || warn "ListBuckets failed (warming up?)"
  docker compose ps; print_summary
}

do_down(){ docker compose down; echo "Container removed. DATA PRESERVED at ${DATA_DIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$DATA_DIR"; echo "Full wipe: container + ${DATA_DIR} removed (objects gone)."; }
do_status(){ docker compose ps || true
  curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:${RUSTFS_API_PORT}/health" 2>/dev/null \
    && echo "S3 API     : OK on :${RUSTFS_API_PORT}" || echo "S3 API     : DOWN on :${RUSTFS_API_PORT}"
  echo "data (host): ${DATA_DIR} ($(sudo du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"; }
do_logs(){ docker compose logs --tail=80 -f; }

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
while [ $# -gt 0 ]; do case "$1" in       # parse flags AFTER the subcommand is stripped
  --gen-keys) GEN=1; shift;;
  --access) CLI_AK="$2"; shift 2;;
  --secret) CLI_SK="$2"; shift 2;;
  *) break;;
esac; done
case "$cmd" in
  up|install)     do_up ;;
  down|uninstall) do_down ;;
  purge)          do_purge ;;
  status)         do_status ;;
  logs)           do_logs ;;
  *) usage; exit 2 ;;
esac
