#!/usr/bin/env bash
# DOKANDAR utility — OpenBao 2.x · Docker Compose single-node · lifecycle wrapper.
# Initialises + unseals the server and enables KV v2; saves the ROOT TOKEN + UNSEAL KEY to .env. File
# storage is a HOST bind mount (${DATA_ROOT}/openbao_docker) and SURVIVES `docker compose down -v`.
#   Usage:  bash setup.sh up | down | purge | status | logs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="$(pwd)/.env"
[ -f .env ] || { echo "No .env here — run:  cp .env.example .env"; exit 2; }
set -a; . ./.env; set +a
: "${DATA_ROOT:=/data}"; : "${BAO_VERSION:=2.5.4}"; : "${BAO_API_PORT:=8200}"
DATA_DIR="${DATA_ROOT}/openbao_docker"; CID=dokandar_openbao_docker_single; ADDR="http://127.0.0.1:${BAO_API_PORT}"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: bash setup.sh up | down | purge | status | logs"; }
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true; export "${k}=${v}"
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }
jget(){ python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (root token shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "============ OpenBao ${BAO_VERSION} (Docker) — connection details ============"; printf '%s' "$(_c 0)"
  cat <<SUM
  API endpoint   : http://${host}:${BAO_API_PORT}   (container 8200; TLS disabled — dev)
  Browser UI     : http://${host}:${BAO_API_PORT}/ui
  Root token     : ${BAO_ROOT_TOKEN}
  Unseal key     : ${BAO_UNSEAL_KEY}
  KV v2 engine   : secret/
  Test from afar : BAO_HOST=${host} BAO_TOKEN=${BAO_ROOT_TOKEN} bash ../test.sh
  Data (host)    : ${DATA_DIR}   (bind mount — survives 'down -v')
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "============================================================================"; printf '%s' "$(_c 0)"
}

do_up(){
  step "1/4  Bind-mount data dir + docker compose up -d"
  sudo mkdir -p "$DATA_DIR"; docker compose up -d
  printf '   waiting for the API'; for _ in $(seq 1 30); do curl -s --max-time 3 "${ADDR}/v1/sys/health?uninitcode=200&sealedcode=200" >/dev/null 2>&1 && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  step "2/4  Initialise (idempotent)"
  local H; H="$(curl -s "${ADDR}/v1/sys/health?uninitcode=200&sealedcode=200" 2>/dev/null)"
  if [ "$(printf '%s' "$H" | jget "['initialized']")" = "True" ]; then ok "already initialised (reusing .env token/key)"
  else
    local INIT; INIT="$(curl -s -X PUT "${ADDR}/v1/sys/init" -d '{"secret_shares":1,"secret_threshold":1}' 2>/dev/null)"
    BAO_ROOT_TOKEN="$(printf '%s' "$INIT" | jget "['root_token']")"; BAO_UNSEAL_KEY="$(printf '%s' "$INIT" | jget "['keys_base64'][0]")"
    set_env_var BAO_ROOT_TOKEN "$BAO_ROOT_TOKEN"; set_env_var BAO_UNSEAL_KEY "$BAO_UNSEAL_KEY"
    set_env_var BAO_API_PORT "$BAO_API_PORT"; set_env_var BAO_VERSION "$BAO_VERSION"; ok "initialised (token + key saved to .env)"
  fi
  step "3/4  Unseal"
  : "${BAO_UNSEAL_KEY:?no unseal key in .env}"
  curl -s -X PUT "${ADDR}/v1/sys/unseal" -d "{\"key\":\"${BAO_UNSEAL_KEY}\"}" >/dev/null 2>&1 || true
  [ "$(curl -s "${ADDR}/v1/sys/health" 2>/dev/null | jget "['sealed']")" = "False" ] && ok "unsealed" || warn "still sealed"
  step "4/4  Enable KV v2 at secret/"
  curl -s -X POST -H "X-Vault-Token: ${BAO_ROOT_TOKEN}" "${ADDR}/v1/sys/mounts/secret" -d '{"type":"kv","options":{"version":"2"}}' >/dev/null 2>&1 || true
  curl -s -H "X-Vault-Token: ${BAO_ROOT_TOKEN}" "${ADDR}/v1/sys/mounts" 2>/dev/null | grep -q '"secret/"' && ok "KV v2 at secret/" || warn "KV enable check failed"
  docker compose ps; print_summary
}

do_down(){ docker compose down; echo "Container removed. DATA (seal+secrets) PRESERVED at ${DATA_DIR}."; }
do_purge(){ docker compose down -v 2>/dev/null || true; sudo rm -rf "$DATA_DIR"; echo "Full wipe: container + ${DATA_DIR} removed (secrets gone)."; }
do_status(){ docker compose ps || true
  local H; H="$(curl -s --max-time 5 "${ADDR}/v1/sys/health?uninitcode=200&sealedcode=200" 2>/dev/null)"
  echo "init/sealed: $(printf '%s' "$H" | jget "['initialized']")/$(printf '%s' "$H" | jget "['sealed']")"
  echo "data (host): ${DATA_DIR} ($(sudo du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"; }
do_logs(){ docker compose logs --tail=80 -f; }

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  up|install)     do_up ;;
  down|uninstall) do_down ;;
  purge)          do_purge ;;
  status)         do_status ;;
  logs)           do_logs ;;
  *) usage; exit 2 ;;
esac
