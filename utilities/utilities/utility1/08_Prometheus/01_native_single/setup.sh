#!/usr/bin/env bash
# DOKANDAR utility — Prometheus 3.12 · native single-node (official binary + systemd), env-file driven.
# Built-in expression-browser web UI + HTTP API on :9090. Prometheus has NO built-in auth — it binds a
# network interface and relies on network/firewall security (production: behind a reverse proxy).
# Data under ${DATA_ROOT}/prometheus (preserved on uninstall; `purge` wipes). Prints connection info.
#   Usage:  sudo bash setup.sh install | uninstall | purge | status
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
set -a; [ -f /etc/dokandar/.env ] && . /etc/dokandar/.env; [ -f "$ENV_FILE" ] && . "$ENV_FILE"; set +a
: "${DATA_ROOT:=/data}"; : "${PROM_VERSION:=3.12.0}"
: "${PROMETHEUS_LISTEN:=0.0.0.0}"; : "${PROMETHEUS_PORT:=9090}"; : "${PROMETHEUS_RETENTION:=15d}"

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: sudo bash setup.sh install | uninstall | purge | status"; }

print_summary(){
  local host="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$host" ] || host="127.0.0.1"
  step "Connection details"
  printf '%s' "$(_c '1;36')"; echo "============== Prometheus ${PROM_VERSION} (native) — connection details =============="; printf '%s' "$(_c 0)"
  cat <<SUM
  HTTP API + UI  : http://${host}:${PROMETHEUS_PORT}   (binds ${PROMETHEUS_LISTEN}; built-in web UI)
  Health / ready : http://${host}:${PROMETHEUS_PORT}/-/healthy , /-/ready
  Sample query   : curl -s 'http://${host}:${PROMETHEUS_PORT}/api/v1/query?query=up'
  Auth           : none (Prometheus has no built-in auth — restrict at the firewall; prod: reverse proxy)
  Test from afar : bash ../test.sh "http://${host}:${PROMETHEUS_PORT}"
  Data directory : ${DATA_ROOT}/prometheus   (retention ${PROMETHEUS_RETENTION})
  Browser UI     : http://${host}:${PROMETHEUS_PORT}  (Prometheus expression browser)
SUM
  printf '%s' "$(_c '1;36')"; echo "===================================================================================="; printf '%s' "$(_c 0)"
}

do_install(){
  step "1/5  Configuration"
  ok "listen=${PROMETHEUS_LISTEN}:${PROMETHEUS_PORT} retention=${PROMETHEUS_RETENTION} data=${DATA_ROOT}/prometheus"
  mkdir -p "$DATA_ROOT/prometheus"
  if [ ! -L /var/lib/prometheus ]; then systemctl stop prometheus 2>/dev/null || true; [ -d /var/lib/prometheus ] && cp -a /var/lib/prometheus/. "$DATA_ROOT/prometheus/" 2>/dev/null || true; rm -rf /var/lib/prometheus; ln -sfn "$DATA_ROOT/prometheus" /var/lib/prometheus; fi

  step "2/5  Installing Prometheus ${PROM_VERSION} (official binary)"
  if ! command -v prometheus >/dev/null 2>&1; then
    apt-get install -y wget curl ca-certificates >/dev/null 2>&1 || true
    wget -qO /tmp/prom.tgz "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz"
    rm -rf /tmp/promx; mkdir -p /tmp/promx; tar -xzf /tmp/prom.tgz -C /tmp/promx --strip-components=1; rm -f /tmp/prom.tgz
    install -m0755 /tmp/promx/prometheus /usr/local/bin/prometheus; install -m0755 /tmp/promx/promtool /usr/local/bin/promtool
  fi
  ok "$(prometheus --version 2>&1 | head -1)"

  step "3/5  prometheus user + config + data dir"
  getent group prometheus >/dev/null || groupadd --system prometheus
  id prometheus >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin -g prometheus prometheus
  mkdir -p /etc/prometheus
  cat > /etc/prometheus/prometheus.yml <<CONF
global:
  scrape_interval: 15s
  evaluation_interval: 15s
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:${PROMETHEUS_PORT}"]
CONF
  chown -R prometheus:prometheus /etc/prometheus "$DATA_ROOT/prometheus"

  step "4/5  systemd service"
  cat > /etc/systemd/system/prometheus.service <<UNIT
[Unit]
Description=Prometheus
After=network-online.target
Wants=network-online.target
[Service]
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=${DATA_ROOT}/prometheus --storage.tsdb.retention.time=${PROMETHEUS_RETENTION} --web.listen-address=${PROMETHEUS_LISTEN}:${PROMETHEUS_PORT} --web.enable-lifecycle
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload; systemctl enable --now prometheus >/dev/null 2>&1 || true

  step "5/5  Verify"
  printf '   waiting for prometheus'
  for _ in $(seq 1 20); do curl -s --max-time 3 "http://localhost:${PROMETHEUS_PORT}/-/ready" >/dev/null 2>&1 && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  curl -s --max-time 5 "http://localhost:${PROMETHEUS_PORT}/-/healthy" 2>/dev/null | grep -qi healthy && ok "Prometheus healthy on :${PROMETHEUS_PORT} (svc=$(systemctl is-active prometheus))" || warn "not ready yet"
  print_summary
}

do_uninstall(){
  step "Stopping Prometheus — DATA PRESERVED at ${DATA_ROOT}/prometheus"
  systemctl stop prometheus >/dev/null 2>&1 || true; systemctl disable prometheus >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/prometheus.service; systemctl daemon-reload 2>/dev/null || true
  [ -L /var/lib/prometheus ] && rm -f /var/lib/prometheus
  rm -f /usr/local/bin/prometheus /usr/local/bin/promtool; rm -rf /etc/prometheus
  ok "Prometheus removed. DATA PRESERVED at ${DATA_ROOT}/prometheus ($(du -sh "${DATA_ROOT}/prometheus" 2>/dev/null | cut -f1 || echo '?'))."
  warn "To remove the data too: sudo bash setup.sh purge"
}
do_purge(){ do_uninstall; step "Purging data dir ${DATA_ROOT}/prometheus"; rm -rf "${DATA_ROOT}/prometheus" || true; ok "data dir removed — full wipe."; }

do_status(){
  : "${PROMETHEUS_PORT:=9090}"
  printf 'prometheus : %s\n' "$(systemctl is-active prometheus 2>/dev/null)"
  curl -s --max-time 5 "http://localhost:${PROMETHEUS_PORT}/-/healthy" 2>/dev/null | grep -qi healthy && echo "health     : OK on :${PROMETHEUS_PORT}" || echo "health     : DOWN on :${PROMETHEUS_PORT}"
  echo "data dir   : ${DATA_ROOT}/prometheus ($(du -sh "${DATA_ROOT}/prometheus" 2>/dev/null | cut -f1 || echo absent))"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  install|do_install)     do_install ;;
  uninstall|do_uninstall) do_uninstall ;;
  purge)                  do_purge ;;
  status)                 do_status ;;
  *) usage; exit 2 ;;
esac
