#!/usr/bin/env bash
# DOKANDAR utility — OpenBao 2.x · native single-node (secrets store), env-file driven.
# OpenBao boots SEALED + uninitialised (no user/password). This setup.sh INITIALISES it (1 unseal key,
# threshold 1 — DEV convenience; production uses 5/3 Shamir), UNSEALS it, enables a KV v2 engine at
# `secret/`, and saves the ROOT TOKEN + UNSEAL KEY to .env (chmod 600). Built-in web UI on :8200/ui.
# Data under ${DATA_ROOT}/openbao (file storage).  Usage:  sudo bash setup.sh install | uninstall | purge | status
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
set -a; [ -f /etc/dokandar/.env ] && . /etc/dokandar/.env; [ -f "$ENV_FILE" ] && . "$ENV_FILE"; set +a
: "${DATA_ROOT:=/data}"; : "${BAO_VERSION:=2.5.4}"
: "${BAO_API_PORT:=8200}"; : "${BAO_LISTEN:=0.0.0.0}"
ADDR="http://127.0.0.1:${BAO_API_PORT}"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: sudo bash setup.sh install | uninstall | purge | status"; }
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }
jget(){ python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null; }   # $1 e.g. ['root_token']

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details (root token shown ONCE)"
  printf '%s' "$(_c '1;36')"; echo "================ OpenBao ${BAO_VERSION} (native) — connection details ================"; printf '%s' "$(_c 0)"
  cat <<SUM
  API endpoint   : http://${host}:${BAO_API_PORT}   (binds ${BAO_LISTEN}; TLS disabled — dev)
  Browser UI     : http://${host}:${BAO_API_PORT}/ui
  Root token     : ${BAO_ROOT_TOKEN}
  Unseal key     : ${BAO_UNSEAL_KEY}
  KV v2 engine   : secret/   (e.g. bao kv put secret/foo k=v)
  Connection URL : BAO_ADDR=http://${host}:${BAO_API_PORT} BAO_TOKEN=${BAO_ROOT_TOKEN}
  Test from afar : BAO_HOST=${host} BAO_TOKEN=${BAO_ROOT_TOKEN} bash ../test.sh
  Data directory : ${DATA_ROOT}/openbao   (file storage)
  Saved to       : ${ENV_FILE} (chmod 600, gitignored)
SUM
  printf '%s' "$(_c '1;36')"; echo "========================================================================"; printf '%s' "$(_c 0)"
}

do_install(){
  step "1/5  Configuration + data dir"
  mkdir -p "$DATA_ROOT/openbao"
  ok "listen=${BAO_LISTEN}:${BAO_API_PORT} storage=${DATA_ROOT}/openbao"

  step "2/5  Installing OpenBao ${BAO_VERSION}"
  if ! command -v bao >/dev/null 2>&1; then
    apt-get install -y wget curl ca-certificates python3 >/dev/null 2>&1 || true
    wget -qO /tmp/bao.deb "https://github.com/openbao/openbao/releases/download/v${BAO_VERSION}/openbao_${BAO_VERSION}_linux_amd64.deb" \
      && dpkg -i /tmp/bao.deb >/dev/null 2>&1; rm -f /tmp/bao.deb
  fi
  command -v bao >/dev/null 2>&1 || { warn "bao not installed"; exit 1; }
  id openbao >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin openbao 2>/dev/null || true
  ok "$(bao --version 2>/dev/null | head -1)"

  step "3/5  Config + systemd + start (server boots SEALED)"
  mkdir -p /etc/openbao
  cat > /etc/openbao/openbao.hcl <<HCL
storage "file" { path = "${DATA_ROOT}/openbao" }
listener "tcp" {
  address     = "${BAO_LISTEN}:${BAO_API_PORT}"
  tls_disable = true
}
api_addr      = "${ADDR}"
ui            = true
disable_mlock = true
HCL
  chown -R openbao:openbao "$DATA_ROOT/openbao" /etc/openbao 2>/dev/null || true
  cat > /etc/systemd/system/openbao.service <<UNIT
[Unit]
Description=OpenBao
After=network-online.target
Wants=network-online.target
[Service]
User=openbao
Group=openbao
ExecStart=/usr/bin/bao server -config=/etc/openbao/openbao.hcl
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload; systemctl enable --now openbao >/dev/null 2>&1 || true
  printf '   waiting for the API'; for _ in $(seq 1 20); do curl -s --max-time 3 "${ADDR}/v1/sys/health?uninitcode=200&sealedcode=200" >/dev/null 2>&1 && { echo ' ✓'; break; }; printf '.'; sleep 2; done

  step "4/5  Initialise + unseal"
  local H; H="$(curl -s "${ADDR}/v1/sys/health?uninitcode=200&sealedcode=200" 2>/dev/null)"
  if [ "$(printf '%s' "$H" | jget "['initialized']")" = "True" ]; then
    ok "already initialised (reusing saved token/keys)"
  else
    local INIT; INIT="$(curl -s -X PUT "${ADDR}/v1/sys/init" -d '{"secret_shares":1,"secret_threshold":1}' 2>/dev/null)"
    BAO_ROOT_TOKEN="$(printf '%s' "$INIT" | jget "['root_token']")"
    BAO_UNSEAL_KEY="$(printf '%s' "$INIT" | jget "['keys_base64'][0]")"
    set_env_var BAO_ROOT_TOKEN "$BAO_ROOT_TOKEN"; set_env_var BAO_UNSEAL_KEY "$BAO_UNSEAL_KEY"
    set_env_var BAO_API_PORT "$BAO_API_PORT"; set_env_var BAO_VERSION "$BAO_VERSION"
    ok "initialised (root token + unseal key saved to .env)"
  fi
  : "${BAO_UNSEAL_KEY:?no unseal key — check .env}"
  curl -s -X PUT "${ADDR}/v1/sys/unseal" -d "{\"key\":\"${BAO_UNSEAL_KEY}\"}" >/dev/null 2>&1 || true
  [ "$(curl -s "${ADDR}/v1/sys/health" 2>/dev/null | jget "['sealed']")" = "False" ] && ok "unsealed" || warn "still sealed"

  step "5/5  Enable KV v2 at secret/ + verify"
  curl -s -X POST -H "X-Vault-Token: ${BAO_ROOT_TOKEN}" "${ADDR}/v1/sys/mounts/secret" -d '{"type":"kv","options":{"version":"2"}}' >/dev/null 2>&1 || true
  curl -s -H "X-Vault-Token: ${BAO_ROOT_TOKEN}" "${ADDR}/v1/sys/mounts" 2>/dev/null | grep -q '"secret/"' && ok "KV v2 enabled at secret/ (svc=$(systemctl is-active openbao))" || warn "KV enable check failed"
  print_summary
}

do_uninstall(){
  step "Stopping OpenBao — DATA PRESERVED at ${DATA_ROOT}/openbao"
  systemctl stop openbao >/dev/null 2>&1 || true; systemctl disable openbao >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/openbao.service; systemctl daemon-reload 2>/dev/null || true
  apt-get purge -y openbao >/dev/null 2>&1 || true; rm -rf /etc/openbao
  ok "OpenBao removed. DATA PRESERVED at ${DATA_ROOT}/openbao ($(du -sh "${DATA_ROOT}/openbao" 2>/dev/null | cut -f1 || echo '?'))."
  warn "To remove the data too: sudo bash setup.sh purge   (deletes secrets + the seal — unrecoverable)"
}
do_purge(){ do_uninstall; rm -rf "${DATA_ROOT}/openbao" || true; ok "data dir removed — full wipe (secrets gone)."; }

do_status(){
  : "${BAO_API_PORT:=8200}"
  printf 'openbao : %s\n' "$(systemctl is-active openbao 2>/dev/null)"
  local H; H="$(curl -s --max-time 5 "${ADDR}/v1/sys/health?uninitcode=200&sealedcode=200" 2>/dev/null)"
  echo "init    : $(printf '%s' "$H" | jget "['initialized']")   sealed: $(printf '%s' "$H" | jget "['sealed']")"
  echo "data    : ${DATA_ROOT}/openbao ($(du -sh "${DATA_ROOT}/openbao" 2>/dev/null | cut -f1 || echo absent))"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  install|do_install)     do_install ;;
  uninstall|do_uninstall) do_uninstall ;;
  purge)                  do_purge ;;
  status)                 do_status ;;
  *) usage; exit 2 ;;
esac
