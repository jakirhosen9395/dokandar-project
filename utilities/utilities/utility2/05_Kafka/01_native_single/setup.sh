#!/usr/bin/env bash
# DOKANDAR utility — Apache Kafka 4.3 (KRaft, no ZooKeeper) · native single-node (NO Docker), env-file driven.
# Single combined broker+controller. PLAINTEXT (the platform's documented Kafka dev posture — production
# uses SASL_SSL); advertised.listeners is set to the host IP so REMOTE producers/consumers can reach it.
# Data under ${DATA_ROOT}/kafka (preserved on uninstall; `purge` wipes). Prints connection info at the end.
#   Usage:  sudo bash setup.sh install | uninstall | purge | status
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
set -a; [ -f /etc/dokandar/.env ] && . /etc/dokandar/.env; [ -f "$ENV_FILE" ] && . "$ENV_FILE"; set +a
: "${DATA_ROOT:=/data}"; : "${KAFKA_VERSION:=4.3.0}"
: "${KAFKA_NODE_ID:=1}"; : "${KAFKA_BROKER_PORT:=9092}"; : "${KAFKA_CONTROLLER_PORT:=9093}"
: "${KAFKA_ADVERTISED_HOST:=$(hostname -I 2>/dev/null | awk '{print $1}')}"; [ -n "$KAFKA_ADVERTISED_HOST" ] || KAFKA_ADVERTISED_HOST=127.0.0.1
SP=/opt/kafka/config/server.properties

_c(){ [ -t 1 ] && printf '\033[%sm' "$1" || true; }
step(){ printf '\n%s==>%s %s%s%s\n' "$(_c '1;34')" "$(_c 0)" "$(_c 1)" "$*" "$(_c 0)"; }
ok(){   printf '   %s✓%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn(){ printf '   %s!%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
usage(){ echo "Usage: sudo bash setup.sh install | uninstall | purge | status"; }
set_env_var(){ local k="$1" v="$2" f="$ENV_FILE"; [ -f "$f" ] || : >"$f"
  { grep -v -E "^[[:space:]]*${k}=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f" 2>/dev/null || true
  [ -n "${SUDO_USER:-}" ] && chown "${SUDO_USER}:" "$f" 2>/dev/null || true; }

print_summary(){
  step "Connection details"
  printf '%s' "$(_c '1;36')"; echo "============== Apache Kafka ${KAFKA_VERSION} (native, KRaft) — connection details =============="; printf '%s' "$(_c 0)"
  cat <<SUM
  Bootstrap server : ${KAFKA_ADVERTISED_HOST}:${KAFKA_BROKER_PORT}   (advertised.listeners)
  Controller       : :${KAFKA_CONTROLLER_PORT}   (internal KRaft quorum, node ${KAFKA_NODE_ID})
  Protocol / auth  : PLAINTEXT, no auth (dev). Production: SASL_SSL — see README.
  CLI smoke test   : /opt/kafka/bin/kafka-topics.sh --bootstrap-server ${KAFKA_ADVERTISED_HOST}:${KAFKA_BROKER_PORT} --list
  Test from afar   : bash ../test.sh "${KAFKA_ADVERTISED_HOST}:${KAFKA_BROKER_PORT}"
  Data directory   : ${DATA_ROOT}/kafka   (KRaft log.dirs)
  Browser UI       : none bundled — Redpanda Console is the companion UI (separate deploy)
  Cluster id saved : ${ENV_FILE}
SUM
  printf '%s' "$(_c '1;36')"; echo "================================================================================================"; printf '%s' "$(_c 0)"
}

do_install(){
  step "1/5  Configuration"
  ok "broker=${KAFKA_BROKER_PORT} controller=${KAFKA_CONTROLLER_PORT} advertised=${KAFKA_ADVERTISED_HOST} node.id=${KAFKA_NODE_ID}"
  mkdir -p "$DATA_ROOT/kafka"
  if [ ! -L /var/lib/kafka ]; then
    systemctl stop kafka 2>/dev/null || true
    [ -d /var/lib/kafka ] && cp -a /var/lib/kafka/. "$DATA_ROOT/kafka/" 2>/dev/null || true
    rm -rf /var/lib/kafka; ln -sfn "$DATA_ROOT/kafka" /var/lib/kafka
  fi

  step "2/5  Installing a JDK (Kafka runs on the JVM)"
  if ! command -v java >/dev/null 2>&1; then
    apt-get update -y >/dev/null; apt-get install -y openjdk-21-jre-headless wget ca-certificates >/dev/null 2>&1 || apt-get install -y default-jre-headless wget ca-certificates >/dev/null
  fi
  ok "JDK: $(java -version 2>&1 | head -1)"

  step "3/5  Installing Apache Kafka ${KAFKA_VERSION} (KRaft, combined broker+controller)"
  if [ ! -x /opt/kafka/bin/kafka-server-start.sh ]; then
    wget -qO /tmp/kafka.tgz "https://downloads.apache.org/kafka/${KAFKA_VERSION}/kafka_2.13-${KAFKA_VERSION}.tgz" \
      || wget -qO /tmp/kafka.tgz "https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/kafka_2.13-${KAFKA_VERSION}.tgz"
    rm -rf /opt/kafka; mkdir -p /opt/kafka; tar -xzf /tmp/kafka.tgz -C /opt/kafka --strip-components=1; rm -f /tmp/kafka.tgz
  fi
  id kafka >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin kafka
  ok "Kafka $(/opt/kafka/bin/kafka-topics.sh --version 2>/dev/null | head -1)"

  step "4/5  KRaft config + format storage"
  sed -i 's|^log.dirs=.*|log.dirs=/var/lib/kafka|' "$SP"
  sed -i "s|^node.id=.*|node.id=${KAFKA_NODE_ID}|" "$SP"
  sed -i "s|^listeners=.*|listeners=PLAINTEXT://:${KAFKA_BROKER_PORT},CONTROLLER://:${KAFKA_CONTROLLER_PORT}|" "$SP"
  sed -i "s|^advertised.listeners=.*|advertised.listeners=PLAINTEXT://${KAFKA_ADVERTISED_HOST}:${KAFKA_BROKER_PORT}|" "$SP"
  sed -i "s|^controller.quorum.voters=.*|controller.quorum.voters=${KAFKA_NODE_ID}@localhost:${KAFKA_CONTROLLER_PORT}|" "$SP"
  chown -R kafka:kafka /var/lib/kafka /opt/kafka
  local CID="${KAFKA_CLUSTER_ID:-$(/opt/kafka/bin/kafka-storage.sh random-uuid)}"
  set_env_var KAFKA_CLUSTER_ID "$CID"; set_env_var KAFKA_BROKER_PORT "$KAFKA_BROKER_PORT"; set_env_var KAFKA_ADVERTISED_HOST "$KAFKA_ADVERTISED_HOST"
  sudo -u kafka env KAFKA_HEAP_OPTS='-Xms256m -Xmx512m' /opt/kafka/bin/kafka-storage.sh format -t "$CID" -c "$SP" --standalone --ignore-formatted >/dev/null 2>&1 \
    || sudo -u kafka env KAFKA_HEAP_OPTS='-Xms256m -Xmx512m' /opt/kafka/bin/kafka-storage.sh format -t "$CID" -c "$SP" --ignore-formatted >/dev/null 2>&1 || true
  ok "storage formatted (cluster-id ${CID})"

  step "5/5  systemd service + verify"
  cat > /etc/systemd/system/kafka.service <<'UNIT'
[Unit]
Description=Apache Kafka (KRaft)
After=network.target
[Service]
User=kafka
Environment=KAFKA_HEAP_OPTS=-Xms256m -Xmx512m
ExecStart=/opt/kafka/bin/kafka-server-start.sh /opt/kafka/config/server.properties
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload; systemctl enable --now kafka >/dev/null 2>&1 || true
  local BS="${KAFKA_ADVERTISED_HOST}:${KAFKA_BROKER_PORT}"
  printf '   waiting for the broker'
  for _ in $(seq 1 20); do /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server "$BS" >/dev/null 2>&1 && { echo ' ✓'; break; }; printf '.'; sleep 2; done
  /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server "$BS" >/dev/null 2>&1 && ok "broker reachable on ${BS} (svc=$(systemctl is-active kafka))" || warn "broker not answering yet (journalctl -u kafka)"
  print_summary
}

do_uninstall(){
  step "Stopping Kafka — DATA PRESERVED at ${DATA_ROOT}/kafka"
  systemctl stop kafka >/dev/null 2>&1 || true; systemctl disable kafka >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/kafka.service; systemctl daemon-reload 2>/dev/null || true
  [ -L /var/lib/kafka ] && rm -f /var/lib/kafka
  rm -rf /opt/kafka
  ok "Kafka removed. DATA PRESERVED at ${DATA_ROOT}/kafka ($(du -sh "${DATA_ROOT}/kafka" 2>/dev/null | cut -f1 || echo '?'))."
  warn "To remove the data too: sudo bash setup.sh purge"
}
do_purge(){ do_uninstall; step "Purging data dir ${DATA_ROOT}/kafka"; rm -rf "${DATA_ROOT}/kafka" || true; id kafka >/dev/null 2>&1 && userdel kafka 2>/dev/null || true; ok "data dir removed — full wipe."; }

do_status(){
  : "${KAFKA_BROKER_PORT:=9092}"; : "${KAFKA_ADVERTISED_HOST:=127.0.0.1}"
  printf 'kafka      : %s\n' "$(systemctl is-active kafka 2>/dev/null)"
  local BS="${KAFKA_ADVERTISED_HOST}:${KAFKA_BROKER_PORT}"
  /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server "$BS" >/dev/null 2>&1 && echo "broker     : reachable on ${BS}" || echo "broker     : DOWN on ${BS}"
  echo "data dir   : ${DATA_ROOT}/kafka ($(du -sh "${DATA_ROOT}/kafka" 2>/dev/null | cut -f1 || echo absent))"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  install|do_install)     do_install ;;
  uninstall|do_uninstall) do_uninstall ;;
  purge)                  do_purge ;;
  status)                 do_status ;;
  *) usage; exit 2 ;;
esac
