#!/usr/bin/env bash
# data/local/collect.sh — writes data/local/result.json (served by GET /data when TENANT=local). Local-machine baseline.
#   ./data/local/collect.sh        (PUBLIC_IP_LOOKUP=off skips the api.ipify.org call)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; OUT="${SCRIPT_DIR}/result.json"
read_os_pretty_name() { if [ -f /etc/os-release ]; then . /etc/os-release; printf '%s' "${PRETTY_NAME:-${ID:-unknown}}"; elif [ "$(uname)" = "Darwin" ]; then printf 'macOS %s' "$(sw_vers -productVersion 2>/dev/null || echo unknown)"; else printf 'unknown'; fi; }
json_escape() { local s="${1-}"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/\\r}"; s="${s//$'\n'/\\n}"; printf '%s' "$s"; }
safe() { local v="${1-}"; if [ -z "$v" ]; then printf '%s' "${2:-unavailable}"; else printf '%s' "$v"; fi; }
HOSTNAME_VAL="$(hostname 2>/dev/null || echo unknown)"; OS_PRETTY="$(read_os_pretty_name)"; KERNEL="$(uname -r 2>/dev/null || echo unknown)"; ARCH="$(uname -m 2>/dev/null || echo unknown)"
UPTIME_PRETTY="$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo unknown)"; NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CPU_MODEL="$(awk -F: '/model name/ {sub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"; [ -z "$CPU_MODEL" ] && CPU_MODEL="unknown"
CPU_CORES="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo unknown)"
CPU_LOAD="$(safe "$(uptime 2>/dev/null | awk -F'load average:' '{gsub(/^ +/, "", $2); print $2}')" unknown)"
MEM_TOTAL="$(safe "$(free -h 2>/dev/null | awk '/Mem:/ {print $2}')" unknown)"; MEM_USED="$(safe "$(free -h 2>/dev/null | awk '/Mem:/ {print $3}')" unknown)"; MEM_AVAILABLE="$(safe "$(free -h 2>/dev/null | awk '/Mem:/ {print $7}')" unknown)"
DISK_TOTAL="$(safe "$(df -h / 2>/dev/null | awk 'NR==2 {print $2}')" unknown)"; DISK_USED="$(safe "$(df -h / 2>/dev/null | awk 'NR==2 {print $3}')" unknown)"; DISK_FREE="$(safe "$(df -h / 2>/dev/null | awk 'NR==2 {print $4}')" unknown)"; DISK_PCT="$(safe "$(df -h / 2>/dev/null | awk 'NR==2 {print $5}')" unknown)"
PRIMARY_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; [ -z "$PRIMARY_IP" ] && PRIMARY_IP="$(ip -4 -o addr show 2>/dev/null | awk '$2 != "lo" {sub(/\/.*/, "", $4); print $4; exit}')"; [ -z "$PRIMARY_IP" ] && PRIMARY_IP="unknown"
PUBLIC_IP="unavailable"; if [ "${PUBLIC_IP_LOOKUP:-on}" != "off" ]; then PUBLIC_IP="$(curl -s -m 3 https://api.ipify.org || true)"; [ -z "$PUBLIC_IP" ] && PUBLIC_IP="unavailable"; fi
case "$CPU_CORES" in ''|*[!0-9]*) CPU_CORES_JSON="\"$(json_escape "$CPU_CORES")\"" ;; *) CPU_CORES_JSON="$CPU_CORES" ;; esac
cat > "$OUT" <<JSON
{
  "kind": "local",
  "service": "17-shipping",
  "collected_at": "$(json_escape "$NOW_UTC")",
  "host": { "hostname": "$(json_escape "$HOSTNAME_VAL")", "os": "$(json_escape "$OS_PRETTY")", "kernel": "$(json_escape "$KERNEL")", "architecture": "$(json_escape "$ARCH")", "uptime": "$(json_escape "$UPTIME_PRETTY")" },
  "cpu": { "model": "$(json_escape "$CPU_MODEL")", "cores": ${CPU_CORES_JSON}, "load_average": "$(json_escape "$CPU_LOAD")" },
  "memory": { "total": "$(json_escape "$MEM_TOTAL")", "used": "$(json_escape "$MEM_USED")", "available": "$(json_escape "$MEM_AVAILABLE")" },
  "storage": { "root_total": "$(json_escape "$DISK_TOTAL")", "root_used": "$(json_escape "$DISK_USED")", "root_free": "$(json_escape "$DISK_FREE")", "root_usage_percent": "$(json_escape "$DISK_PCT")" },
  "network": { "primary_ip": "$(json_escape "$PRIMARY_IP")", "public_ip": "$(json_escape "$PUBLIC_IP")" }
}
JSON
chmod 644 "$OUT"; echo "Wrote $OUT"
