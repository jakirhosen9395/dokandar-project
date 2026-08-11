#!/usr/bin/env bash
# DOKANDAR utility — OpenBao 2.x · Docker Compose HA cluster (3-node integrated Raft) · wrapper.
# Initialises node 1, unseals all 3 nodes with the SAME key (they retry_join into one Raft quorum),
# enables KV v2. Saves the ROOT TOKEN + UNSEAL KEY to .env. Per-node Raft data are HOST bind mounts.
#   Usage:  bash setup.sh up | down | purge | status | acceptance | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || { echo "No .env here — run:  cp .env.example .env"; exit 2; }
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${BAO_VERSION:=2.5.4}"
: "${BAO_PORT1:=8200}"; : "${BAO_PORT2:=8202}"; : "${BAO_PORT3:=8203}"
DATA_DIR="${DATA_ROOT}/openbao_cluster"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up | down | purge | status | acceptance | logs"; }
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true; export "${k}=${v}"
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }
jget(){ python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null; }
A1="http://localhost:${BAO_PORT1}"; A2="http://localhost:${BAO_PORT2}"; A3="http://localhost:${BAO_PORT3}"
sealed(){ curl -s "$1/v1/sys/health?uninitcode=200&sealedcode=200&standbycode=200" 2>/dev/null | jget "['sealed']"; }
unseal(){ curl -s -X PUT "$1/v1/sys/unseal" -d "{\"key\":\"${BAO_UNSEAL_KEY}\"}" >/dev/null 2>&1 || true; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (root token shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "========= OpenBao ${BAO_VERSION} HA cluster (3-node Raft) — connection details ========="; printf '%s' "$(_c 0)"
  cat <<SUM
  API (node 1)   : http://${host}:${BAO_PORT1}   (also :${BAO_PORT2} node2, :${BAO_PORT3} node3; writes -> leader)
  Browser UI     : http://${host}:${BAO_PORT1}/ui
  Root token     : ${BAO_ROOT_TOKEN}
  Unseal key     : ${BAO_UNSEAL_KEY}   (one key unseals ALL 3 nodes)
  KV v2 engine   : secret/   (Raft-replicated to all 3)
  Test (cluster) : BAO_HOST=${host} BAO_API_PORT=${BAO_PORT1} BAO_TOKEN=${BAO_ROOT_TOKEN} bash ../test.sh
  Verify HA      : bash setup.sh acceptance
  Data (host)    : ${DATA_DIR}/{n1,n2,n3}   (bind mounts — survive 'down -v')
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "==========================================================================================="; printf '%s' "$(_c 0)"
}

do_up(){
  step "1/5  Per-node data dirs + docker compose up (3 nodes)"
  for n in 1 2 3; do sudo mkdir -p "$DATA_DIR/n$n"; done
  docker compose up -d
  printf '   waiting for node 1 API'; for _ in $(seq 1 30); do curl -s --max-time 3 "${A1}/v1/sys/health?uninitcode=200&sealedcode=200" >/dev/null 2>&1 && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  step "2/5  Initialise node 1 (idempotent)"
  if [ "$(curl -s "${A1}/v1/sys/health?uninitcode=200&sealedcode=200" 2>/dev/null | jget "['initialized']")" = "True" ]; then ok "already initialised (reusing .env)"
  else
    local INIT; INIT="$(curl -s -X PUT "${A1}/v1/sys/init" -d '{"secret_shares":1,"secret_threshold":1}' 2>/dev/null)"
    BAO_ROOT_TOKEN="$(printf '%s' "$INIT" | jget "['root_token']")"; BAO_UNSEAL_KEY="$(printf '%s' "$INIT" | jget "['keys_base64'][0]")"
    set_env_var BAO_ROOT_TOKEN "$BAO_ROOT_TOKEN"; set_env_var BAO_UNSEAL_KEY "$BAO_UNSEAL_KEY"
    set_env_var BAO_PORT1 "$BAO_PORT1"; set_env_var BAO_PORT2 "$BAO_PORT2"; set_env_var BAO_PORT3 "$BAO_PORT3"; set_env_var BAO_VERSION "$BAO_VERSION"
    ok "initialised (token + key saved)"
  fi
  : "${BAO_UNSEAL_KEY:?no unseal key in .env}"
  step "3/5  Unseal node 1 (the leader)"
  unseal "$A1"; sleep 3; [ "$(sealed "$A1")" = "False" ] && ok "node 1 unsealed" || warn "node 1 still sealed"
  step "4/5  Join + unseal nodes 2 + 3 (retry_join into the Raft quorum)"
  for a in "$A2" "$A3"; do
    for _ in $(seq 1 15); do unseal "$a"; [ "$(sealed "$a")" = "False" ] && break; sleep 2; done
    [ "$(sealed "$a")" = "False" ] && ok "${a#http://localhost:} unsealed + joined" || warn "${a#http://localhost:} not unsealed yet"
  done
  step "5/5  Enable KV v2 + Raft peers"
  curl -s -X POST -H "X-Vault-Token: ${BAO_ROOT_TOKEN}" "${A1}/v1/sys/mounts/secret" -d '{"type":"kv","options":{"version":"2"}}' >/dev/null 2>&1 || true
  local peers; peers="$(curl -s -H "X-Vault-Token: ${BAO_ROOT_TOKEN}" "${A1}/v1/sys/storage/raft/configuration" 2>/dev/null | grep -oE '"node_id":"bao-[123]"' | wc -l | tr -d ' ')"
  ok "KV v2 enabled; Raft peers: ${peers}/3"
  docker compose ps; print_summary
}

do_acceptance(){
  : "${BAO_ROOT_TOKEN:?}"
  echo "== (1) Raft peers == 3 =="
  curl -s -H "X-Vault-Token: ${BAO_ROOT_TOKEN}" "${A1}/v1/sys/storage/raft/configuration" 2>/dev/null | grep -oE '"node_id":"bao-[123]","address"[^}]*"leader":(true|false)' | sed 's/^/   /'
  local n; n="$(curl -s -H "X-Vault-Token: ${BAO_ROOT_TOKEN}" "${A1}/v1/sys/storage/raft/configuration" 2>/dev/null | grep -oE '"node_id":"bao-[123]"' | wc -l | tr -d ' ')"
  [ "$n" = 3 ] && echo "OK: 3 voters" || echo "FAIL: ${n} peers"
  echo "== (2) write on node 1, read via node 2 (Raft-replicated) =="
  curl -s -H "X-Vault-Token: ${BAO_ROOT_TOKEN}" -X POST "${A1}/v1/secret/data/ha_check" -d '{"data":{"v":"replicated"}}' >/dev/null 2>&1; sleep 1
  local r; r="$(curl -s -H "X-Vault-Token: ${BAO_ROOT_TOKEN}" "${A2}/v1/secret/data/ha_check" 2>/dev/null | grep -o replicated | head -1)"
  [ "$r" = replicated ] && echo "OK: node 2 returns the secret written on node 1" || echo "FAIL: not replicated"
  curl -s -H "X-Vault-Token: ${BAO_ROOT_TOKEN}" -X DELETE "${A1}/v1/secret/metadata/ha_check" >/dev/null 2>&1 || true
}

do_down(){ docker compose down; echo "Containers removed. DATA (Raft+seal) PRESERVED at ${DATA_DIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$DATA_DIR"; echo "Full wipe: containers + ${DATA_DIR} removed (secrets gone)."; }
do_status(){ docker compose ps || true; echo "data: ${DATA_DIR} ($(sudo du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"; }
do_logs(){ docker compose logs --tail=80 -f; }

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  up|install) do_up ;; down|uninstall) do_down ;; purge) do_purge ;; status) do_status ;; acceptance) do_acceptance ;; logs) do_logs ;;
  *) usage; exit 2 ;;
esac
