#!/usr/bin/env bash
# DOKANDAR utility — RustFS · Docker Compose HA cluster (4 nodes, one distributed erasure set).
# Auto-generates the S3 keys, brings up all 4 nodes, and runs the acceptance gate: S3 reachable; an object
# written via node1 reads back via node2 (shared namespace); a node-down failover write. Per-node data are
# HOST bind mounts (survive `down -v`).
#   Usage:  bash setup.sh up [--gen-keys|--access KEY|--secret KEY] | down | purge | status | accept | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${RFS_API1:=9000}"; : "${RFS_API2:=9002}"; : "${RFS_CONSOLE1:=9001}"
CDIR="${DATA_ROOT}/rustfs_cluster"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up [--gen-keys|--access KEY|--secret KEY] | down | purge | status | accept | logs"; }
genhex(){ local s; s="$(od -An -tx1 -N40 /dev/urandom | tr -dc 'a-f0-9')"; printf '%s' "${s:0:${1:-40}}"; }  # SIGPIPE-safe
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true; export "${k}=${v}"
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }
# mc against a node by host port. Args: <port> mc-subcommand...   (alias n1 → that port)
MC(){ local p="$1"; shift; docker run --rm -i --network host -e MC_HOST_n="http://${RUSTFS_ACCESS_KEY}:${RUSTFS_SECRET_KEY}@127.0.0.1:${p}" minio/mc:latest --no-color "$@"; }
phealth(){ curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${1}/health" 2>/dev/null || echo 000; }

GEN=0; CLI_AK=""; CLI_SK=""

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (keys shown ONCE — copy them into your test env)"
  printf '%s' "$(_c '1;36')"; echo "===== RustFS HA cluster (4-node distributed) — connection details ====="; printf '%s' "$(_c 0)"
  cat <<SUM
  S3 endpoints   : http://${host}:${RFS_API1} (node1), http://${host}:${RFS_API2} (node2)
                   any node serves the SAME shared, erasure-coded namespace
  Access key     : ${RUSTFS_ACCESS_KEY}
  Secret key     : ${RUSTFS_SECRET_KEY}
  Console UI     : http://${host}:${RFS_CONSOLE1}   (node1 console — log in with the keys)
  Test from afar : RUSTFS_HOST=${host} RUSTFS_API_PORT=${RFS_API1} RUSTFS_ACCESS_KEY=${RUSTFS_ACCESS_KEY} RUSTFS_SECRET_KEY=${RUSTFS_SECRET_KEY} bash ../test.sh
  Data (host)    : ${CDIR}/n{1,2,3,4}   (bind mounts — survive 'down -v')
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "======================================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  step "1/3  Resolve S3 keys + per-node data dirs"
  [ -n "$CLI_AK" ] && RUSTFS_ACCESS_KEY="$CLI_AK"; [ -n "$CLI_SK" ] && RUSTFS_SECRET_KEY="$CLI_SK"
  if [ "$GEN" = 1 ] || [ -z "${RUSTFS_ACCESS_KEY:-}" ]; then RUSTFS_ACCESS_KEY="$(genhex 20)"; ok "access key: generated"; else ok "access key: reused"; fi
  if [ "$GEN" = 1 ] || [ -z "${RUSTFS_SECRET_KEY:-}" ]; then RUSTFS_SECRET_KEY="$(genhex 40)"; ok "secret key: generated"; else ok "secret key: reused"; fi
  set_env_var RUSTFS_ACCESS_KEY "$RUSTFS_ACCESS_KEY"; set_env_var RUSTFS_SECRET_KEY "$RUSTFS_SECRET_KEY"
  set_env_var RFS_API1 "$RFS_API1"; set_env_var RFS_API2 "$RFS_API2"
  for n in 1 2 3 4; do sudo mkdir -p "$CDIR/n$n/data" "$CDIR/n$n/logs"; done
  sudo chown -R 10001:10001 "$CDIR" 2>/dev/null || true; sudo chmod -R 755 "$CDIR" 2>/dev/null || true

  step "2/3  docker compose up -d (4 nodes form the erasure set)"
  docker compose up -d
  printf '   waiting for node 1 S3 API'; local h=000
  for _ in $(seq 1 40); do h="$(phealth "$RFS_API1")"; [ "$h" = 200 ] && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  [ "$h" = 200 ] && ok "node 1 live on :${RFS_API1}" || warn "node 1 not answering yet"

  step "3/3  Verify the cluster (S3 reachable on node1 + node2)"
  MC "$RFS_API1" ls n >/dev/null 2>&1 && ok "node1 S3 ListBuckets OK" || warn "node1 S3 not ready"
  for _ in $(seq 1 15); do [ "$(phealth "$RFS_API2")" = 200 ] && break; sleep 2; done
  MC "$RFS_API2" ls n >/dev/null 2>&1 && ok "node2 S3 ListBuckets OK" || warn "node2 S3 not ready"
  docker compose ps
  print_summary
  do_accept || warn "acceptance had warnings — see above"
}

do_accept(){
  step "Acceptance — 4-node erasure set / write-here-read-there / node-down failover"
  local rc=0 B="accept-$(date +%s)" T1 T2
  echo "== (1) all 4 nodes healthy =="
  local up=0; for p in "$RFS_API1" "$RFS_API2"; do [ "$(phealth "$p")" = 200 ] && up=$((up+1)); done
  # nodes 3/4 are internal (no published port) — verify via the container health
  local internal; internal="$(docker compose ps --format '{{.Name}} {{.Status}}' 2>/dev/null | grep -c 'Up' || true)"
  echo "   published-node health: ${up}/2 ; containers up: ${internal}/4"
  { [ "$up" = 2 ] && [ "${internal:-0}" -ge 4 ]; } && ok "4 nodes up, S3 reachable" || { warn "cluster not fully up"; rc=1; }

  echo "== (2) write via node1, read via node2 (shared erasure-coded namespace) =="
  MC "$RFS_API1" mb --ignore-existing "n/$B" >/dev/null 2>&1 || true
  T1="dokandar-rustfs-cluster $(date -u +%FT%TZ)"
  printf '%s' "$T1" | MC "$RFS_API1" pipe "n/$B/probe.txt" >/dev/null 2>&1 || true
  local r2=0; for _ in $(seq 1 10); do [ "$(MC "$RFS_API2" cat "n/$B/probe.txt" 2>/dev/null)" = "$T1" ] && { r2=1; break; }; sleep 1; done
  [ "$r2" = 1 ] && ok "node2 returns the object written on node1" || { warn "node2 mismatch"; rc=1; }

  echo "== (3) failover: stop node 4, write still works (erasure quorum) =="
  docker compose stop rustfs4 >/dev/null 2>&1 || true; sleep 5
  T2="survived-node4-down $(date -u +%FT%TZ)"
  printf '%s' "$T2" | MC "$RFS_API1" pipe "n/$B/probe2.txt" >/dev/null 2>&1 || true
  [ "$(MC "$RFS_API1" cat "n/$B/probe2.txt" 2>/dev/null)" = "$T2" ] && ok "PUT+GET succeeded with node 4 down" || { warn "write failed with node 4 down"; rc=1; }
  [ "$(MC "$RFS_API2" cat "n/$B/probe.txt" 2>/dev/null)" = "$T1" ] && ok "old object still readable via node2" || { warn "old object lost"; rc=1; }
  docker compose start rustfs4 >/dev/null 2>&1 || true; sleep 4

  MC "$RFS_API1" rm --recursive --force "n/$B" >/dev/null 2>&1 || true; MC "$RFS_API1" rb --force "n/$B" >/dev/null 2>&1 || true
  [ "$rc" = 0 ] && ok "ACCEPTANCE PASS" || warn "ACCEPTANCE had failures"
  return "$rc"
}

do_down(){ docker compose down; echo "Containers removed. DATA PRESERVED at ${CDIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$CDIR"; echo "Full wipe: containers + ${CDIR} removed."; }
do_status(){ docker compose ps || true
  for p in "$RFS_API1" "$RFS_API2"; do echo "  S3 :${p} health -> $(phealth "$p")"; done
  echo "data (host): ${CDIR} ($(sudo du -sh "$CDIR" 2>/dev/null | cut -f1 || echo absent))"; }
do_logs(){ docker compose logs --tail=80 -f; }

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
while [ $# -gt 0 ]; do case "$1" in
  --gen-keys) GEN=1; shift;;
  --access) CLI_AK="$2"; shift 2;;
  --secret) CLI_SK="$2"; shift 2;;
  *) break;;
esac; done
case "$cmd" in
  up|install)     do_up ;;
  accept)         do_accept ;;
  down|uninstall) do_down ;;
  purge)          do_purge ;;
  status)         do_status ;;
  logs)           do_logs ;;
  *) usage; exit 2 ;;
esac
