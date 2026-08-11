#!/usr/bin/env bash
# DOKANDAR utility — ScyllaDB 2026.1 · native single-node wide-column store, env-file driven.
# Installs from the official ScyllaDB apt repo (forced to a SUPPORTED codename — ScyllaDB ships
# noble/jammy, not resolute), runs `scylla_dev_mode_setup --developer-mode 1` (skips the invasive
# scylla_setup host tuning so it runs on a shared box), configures scylla.yaml, and starts scylla-server.
# ScyllaDB has no auth by default and no browser UI (CQL database — cqlsh/nodetool). Data under
# ${DATA_ROOT}/scylla.  Usage:  sudo bash setup.sh install | uninstall | purge | status
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
set -a; [ -f /etc/dokandar/.env ] && . /etc/dokandar/.env; [ -f "$ENV_FILE" ] && . "$ENV_FILE"; set +a
: "${DATA_ROOT:=/data}"; : "${SCYLLA_VERSION_LINE:=2026.1}"
: "${SCYLLA_CQL_PORT:=9042}"; : "${SCYLLA_CLUSTER_NAME:=dokandar}"
: "${SCYLLA_LISTEN_ADDRESS:=$(hostname -I 2>/dev/null | awk '{print $1}')}"; : "${SCYLLA_LISTEN_ADDRESS:=127.0.0.1}"
: "${SCYLLA_RPC_ADDRESS:=0.0.0.0}"
# ScyllaDB has no apt repo for resolute(26.04) — its packages target noble(24.04)/jammy(22.04). Force one.
: "${SCYLLA_REPO_CODENAME:=noble}"
DATA_DIR="${DATA_ROOT}/scylla"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: sudo bash setup.sh install | uninstall | purge | status"; }

print_summary(){
  local host="${HOST_IP:-${SCYLLA_LISTEN_ADDRESS}}"
  step "Connection details"
  printf '%s' "$(_c '1;36')"; echo "============ ScyllaDB ${SCYLLA_VERSION_LINE} (native) — connection details ============"; printf '%s' "$(_c 0)"
  cat <<SUM
  CQL endpoint   : ${host}:${SCYLLA_CQL_PORT}
  Cluster name   : ${SCYLLA_CLUSTER_NAME}   (single node)
  Auth           : none (authenticator off by default — no username/password)
  Browser UI     : none — N/A (CQL database; interact via cqlsh / nodetool)
  cqlsh smoke    : cqlsh ${host} ${SCYLLA_CQL_PORT} -e "SELECT release_version FROM system.local;"
  Test from afar : SCYLLA_HOST=${host} SCYLLA_CQL_PORT=${SCYLLA_CQL_PORT} bash ../test.sh
  Data directory : ${DATA_DIR}   (symlinked to /var/lib/scylla)
  Mode           : developer-mode 1 (host tuning skipped — single-box/shared; NOT a production tuning)
SUM
  printf '%s' "$(_c '1;36')"; echo "==============================================================================="; printf '%s' "$(_c 0)"
}

do_install(){
  step "1/5  Configuration + data dir"
  mkdir -p "$DATA_DIR"; if [ ! -L /var/lib/scylla ]; then systemctl stop scylla-server 2>/dev/null || true; [ -d /var/lib/scylla ] && cp -a /var/lib/scylla/. "$DATA_DIR/" 2>/dev/null || true; rm -rf /var/lib/scylla; ln -sfn "$DATA_DIR" /var/lib/scylla; fi
  ok "cluster=${SCYLLA_CLUSTER_NAME} listen=${SCYLLA_LISTEN_ADDRESS} rpc=${SCYLLA_RPC_ADDRESS} cql=${SCYLLA_CQL_PORT} data=${DATA_DIR}"

  step "2/5  Official ScyllaDB apt repo (codename forced to ${SCYLLA_REPO_CODENAME}) + install"
  if ! command -v scylla >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y wget gnupg curl ca-certificates apt-transport-https >/dev/null 2>&1
    mkdir -p /etc/apt/keyrings
    # The repo signing key is C503C686B007F39E. Import it and EXPORT it as a binary keyring — apt's
    # `signed-by` REJECTS a gpg keybox ("unsupported filetype"); only the --export (dearmored) form works.
    install -d -m 700 /tmp/scygpg
    GNUPGHOME=/tmp/scygpg gpg --batch --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys "${SCYLLA_REPO_KEY:-C503C686B007F39E}" >/dev/null 2>&1 || true
    GNUPGHOME=/tmp/scygpg gpg --batch --export "${SCYLLA_REPO_KEY:-C503C686B007F39E}" > /etc/apt/keyrings/scylladb.gpg 2>/dev/null; rm -rf /tmp/scygpg
    # The ScyllaDB .list is CODENAME-INDEPENDENT (debian-ubuntu/scylladb-<ver> stable main) — it works on
    # resolute even though ScyllaDB doesn't publish a resolute-specific suite. SCYLLA_REPO_CODENAME is unused.
    wget -qO /etc/apt/sources.list.d/scylla.list "http://downloads.scylladb.com/deb/ubuntu/scylla-${SCYLLA_VERSION_LINE}.list" || true
    apt-get update -y >/dev/null 2>&1 || warn "apt update had warnings"
    apt-get install -y scylla >/dev/null 2>&1 || { warn "scylla package not installable — see the native note in README"; exit 1; }
  fi
  ok "installed: $(scylla --version 2>/dev/null | head -1 || dpkg-query -W -f='${Version}' scylla 2>/dev/null)"

  step "3/5  Developer mode (skip invasive host tuning) + scylla.yaml"
  scylla_dev_mode_setup --developer-mode 1 >/dev/null 2>&1 || true
  id scylla >/dev/null 2>&1 && chown -R scylla:scylla "$DATA_DIR" 2>/dev/null || true
  if [ -f /etc/scylla/scylla.yaml ]; then
    local Y=/etc/scylla/scylla.yaml
    sed -i "s/^cluster_name:.*/cluster_name: '${SCYLLA_CLUSTER_NAME}'/" "$Y" 2>/dev/null || true
    grep -qE '^cluster_name:' "$Y" || echo "cluster_name: '${SCYLLA_CLUSTER_NAME}'" >> "$Y"
    sed -i "s/^listen_address:.*/listen_address: ${SCYLLA_LISTEN_ADDRESS}/" "$Y" 2>/dev/null || true
    sed -i "s/^rpc_address:.*/rpc_address: ${SCYLLA_RPC_ADDRESS}/" "$Y" 2>/dev/null || true
    sed -i "s/^native_transport_port:.*/native_transport_port: ${SCYLLA_CQL_PORT}/" "$Y" 2>/dev/null || true
    sed -i "s/^\(\s*\)- seeds:.*/\1- seeds: \"${SCYLLA_LISTEN_ADDRESS}\"/" "$Y" 2>/dev/null || true
    # Scylla REFUSES to start with rpc_address=0.0.0.0 unless broadcast_rpc_address (the address gossiped
    # to clients) is set — point it at this node's reachable IP.
    sed -i "/^broadcast_rpc_address:/d" "$Y" 2>/dev/null || true
    case "$SCYLLA_RPC_ADDRESS" in 0.0.0.0|::) echo "broadcast_rpc_address: ${SCYLLA_LISTEN_ADDRESS}" >> "$Y" ;; esac
  fi
  ok "developer-mode on; scylla.yaml configured"

  step "4/5  Start scylla-server"
  systemctl enable scylla-server >/dev/null 2>&1 || true; systemctl restart scylla-server >/dev/null 2>&1 || true
  printf '   waiting for CQL'; local up=0
  for _ in $(seq 1 40); do cqlsh "${SCYLLA_LISTEN_ADDRESS}" "${SCYLLA_CQL_PORT}" -e "SELECT now() FROM system.local;" >/dev/null 2>&1 && { echo ' ✓'; up=1; break; }; printf '.'; sleep 3; done
  [ "$up" = 1 ] && ok "CQL live (svc=$(systemctl is-active scylla-server))" || warn "CQL not answering yet (svc=$(systemctl is-active scylla-server))"

  step "5/5  Verify (release_version)"
  local ver; ver="$(cqlsh "${SCYLLA_LISTEN_ADDRESS}" "${SCYLLA_CQL_PORT}" -e "SELECT release_version FROM system.local;" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  [ -n "$ver" ] && ok "query OK — release ${ver}" || warn "query failed yet"
  print_summary
}

do_uninstall(){
  step "Stopping scylla-server — DATA PRESERVED at ${DATA_DIR}"
  systemctl stop scylla-server >/dev/null 2>&1 || true; systemctl disable scylla-server >/dev/null 2>&1 || true
  apt-get purge -y scylla 'scylla-*' >/dev/null 2>&1 || true; apt-get autoremove --purge -y >/dev/null 2>&1 || true
  rm -f /etc/apt/sources.list.d/scylla.list /etc/apt/keyrings/scylladb.gpg
  if [ -L /var/lib/scylla ]; then rm -f /var/lib/scylla; fi
  ok "ScyllaDB + repo removed. DATA PRESERVED at ${DATA_DIR} ($(du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo '?'))."
  warn "To remove the data too: sudo bash setup.sh purge"
}
do_purge(){ do_uninstall; rm -rf "$DATA_DIR" /var/lib/scylla /etc/scylla || true; ok "data dir removed — full wipe."; }

do_status(){
  : "${SCYLLA_CQL_PORT:=9042}"; : "${SCYLLA_LISTEN_ADDRESS:=127.0.0.1}"
  printf 'scylla-server : %s\n' "$(systemctl is-active scylla-server 2>/dev/null)"
  cqlsh "${SCYLLA_LISTEN_ADDRESS}" "${SCYLLA_CQL_PORT}" -e "SELECT release_version FROM system.local;" >/dev/null 2>&1 \
    && echo "CQL           : OK on ${SCYLLA_LISTEN_ADDRESS}:${SCYLLA_CQL_PORT}" || echo "CQL           : DOWN"
  command -v nodetool >/dev/null 2>&1 && nodetool status 2>/dev/null | grep -E '^UN|^DN' | sed 's/^/   /' || true
  echo "data          : ${DATA_DIR} ($(du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo absent))"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  install|do_install)     do_install ;;
  uninstall|do_uninstall) do_uninstall ;;
  purge)                  do_purge ;;
  status)                 do_status ;;
  *) usage; exit 2 ;;
esac
