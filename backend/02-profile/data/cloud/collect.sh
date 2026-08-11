#!/usr/bin/env bash
# data/cloud/collect.sh
#
# Collects information about the AWS EC2 instance this script is running on
# (EC2 metadata via IMDSv2 -- instance id, type, AMI, public/private IPs,
# region, AZ, IAM role) plus the local-machine baseline (hostname, OS, CPU,
# RAM, storage, uptime) and writes the result as JSON to this script's sibling
# result.json (i.e. data/cloud/result.json at the repository root).
#
# After the file is written, GET /data on the running profile_service container
# will return this content immediately PROVIDED the container is configured
# with TENANT=cloud. The data directory is bind-mounted so no container
# restart is required.
#
# Usage (from anywhere on the EC2):
#   ./data/cloud/collect.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${SCRIPT_DIR}/result.json"

# ---------- helpers ----------

read_os_pretty_name() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s' "${PRETTY_NAME:-${ID:-unknown}}"
    else
        printf 'unknown'
    fi
}

json_escape() {
    local s="${1-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

safe() {
    local v="${1-}"
    if [ -z "$v" ] || echo "$v" | grep -Eiq "^[[:space:]]*$|404|not found"; then
        printf '%s' "${2:-unavailable}"
    else
        printf '%s' "$v"
    fi
}

# EC2 IMDSv2 token (fall back to IMDSv1 if v2 endpoint isn't responsive).
TOKEN="$(curl -s -m 2 -X PUT \
    http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' 2>/dev/null || true)"

meta() {
    if [ -n "$TOKEN" ]; then
        curl -s -m 2 -H "X-aws-ec2-metadata-token: $TOKEN" \
            "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || true
    else
        curl -s -m 2 \
            "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || true
    fi
}

dyn() {
    if [ -n "$TOKEN" ]; then
        curl -s -m 2 -H "X-aws-ec2-metadata-token: $TOKEN" \
            "http://169.254.169.254/latest/dynamic/$1" 2>/dev/null || true
    else
        curl -s -m 2 \
            "http://169.254.169.254/latest/dynamic/$1" 2>/dev/null || true
    fi
}

# ---------- collect: machine baseline ----------

HOSTNAME_VAL="$(hostname 2>/dev/null || echo unknown)"
OS_PRETTY="$(read_os_pretty_name)"
KERNEL="$(uname -r 2>/dev/null || echo unknown)"
ARCH="$(uname -m 2>/dev/null || echo unknown)"
UPTIME_PRETTY="$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo unknown)"
NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

CPU_MODEL="$(awk -F: '/model name/ {sub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
[ -z "$CPU_MODEL" ] && CPU_MODEL="unknown"
CPU_CORES="$(nproc 2>/dev/null || echo unknown)"
CPU_LOAD="$(uptime 2>/dev/null | awk -F'load average:' '{gsub(/^ +/, "", $2); print $2}')"
CPU_LOAD="$(safe "$CPU_LOAD" "unknown")"

MEM_TOTAL="$(free -h 2>/dev/null | awk '/Mem:/ {print $2}')"
MEM_USED="$(free -h 2>/dev/null | awk '/Mem:/ {print $3}')"
MEM_AVAILABLE="$(free -h 2>/dev/null | awk '/Mem:/ {print $7}')"
MEM_TOTAL="$(safe "$MEM_TOTAL" "unknown")"
MEM_USED="$(safe "$MEM_USED" "unknown")"
MEM_AVAILABLE="$(safe "$MEM_AVAILABLE" "unknown")"

DISK_TOTAL="$(df -h / 2>/dev/null | awk 'NR==2 {print $2}')"
DISK_USED="$(df -h / 2>/dev/null | awk 'NR==2 {print $3}')"
DISK_FREE="$(df -h / 2>/dev/null | awk 'NR==2 {print $4}')"
DISK_PCT="$(df -h / 2>/dev/null | awk 'NR==2 {print $5}')"
DISK_TOTAL="$(safe "$DISK_TOTAL" "unknown")"
DISK_USED="$(safe "$DISK_USED" "unknown")"
DISK_FREE="$(safe "$DISK_FREE" "unknown")"
DISK_PCT="$(safe "$DISK_PCT" "unknown")"

# ---------- collect: EC2 metadata ----------

INSTANCE_ID="$(safe       "$(meta instance-id)"                                                           "unavailable")"
INSTANCE_TYPE="$(safe     "$(meta instance-type)"                                                         "unavailable")"
AMI_ID="$(safe            "$(meta ami-id)"                                                                "unavailable")"
PUBLIC_IPV4="$(safe       "$(meta public-ipv4)"                                                           "unavailable")"
LOCAL_IPV4="$(safe        "$(meta local-ipv4)"                                                            "unavailable")"
HOSTNAME_AWS="$(safe      "$(meta hostname)"                                                              "unavailable")"
PUBLIC_HOSTNAME="$(safe   "$(meta public-hostname)"                                                       "unavailable")"
AVAILABILITY_ZONE="$(safe "$(meta placement/availability-zone)"                                           "unavailable")"
REGION="$(safe            "$(dyn instance-identity/document | awk -F'\"' '/region/ {print $4}')"          "unavailable")"
AZ_ID="$(safe             "$(meta placement/availability-zone-id)"                                        "unavailable")"
IAM_ROLE="$(safe          "$(meta iam/security-credentials/)"                                             "no IAM role attached")"
RESERVATION_ID="$(safe    "$(meta reservation-id)"                                                        "unavailable")"

case "$CPU_CORES" in
    ''|*[!0-9]*) CPU_CORES_JSON="\"$(json_escape "$CPU_CORES")\"" ;;
    *)           CPU_CORES_JSON="$CPU_CORES" ;;
esac

# ---------- write ----------

cat > "$OUT" <<JSON
{
  "kind": "cloud",
  "provider": "aws-ec2",
  "collected_at": "$(json_escape "$NOW_UTC")",
  "host": {
    "hostname": "$(json_escape "$HOSTNAME_VAL")",
    "os": "$(json_escape "$OS_PRETTY")",
    "kernel": "$(json_escape "$KERNEL")",
    "architecture": "$(json_escape "$ARCH")",
    "uptime": "$(json_escape "$UPTIME_PRETTY")"
  },
  "cpu": {
    "model": "$(json_escape "$CPU_MODEL")",
    "cores": ${CPU_CORES_JSON},
    "load_average": "$(json_escape "$CPU_LOAD")"
  },
  "memory": {
    "total": "$(json_escape "$MEM_TOTAL")",
    "used": "$(json_escape "$MEM_USED")",
    "available": "$(json_escape "$MEM_AVAILABLE")"
  },
  "storage": {
    "root_total": "$(json_escape "$DISK_TOTAL")",
    "root_used": "$(json_escape "$DISK_USED")",
    "root_free": "$(json_escape "$DISK_FREE")",
    "root_usage_percent": "$(json_escape "$DISK_PCT")"
  },
  "ec2": {
    "instance_id": "$(json_escape "$INSTANCE_ID")",
    "instance_type": "$(json_escape "$INSTANCE_TYPE")",
    "ami_id": "$(json_escape "$AMI_ID")",
    "region": "$(json_escape "$REGION")",
    "availability_zone": "$(json_escape "$AVAILABILITY_ZONE")",
    "availability_zone_id": "$(json_escape "$AZ_ID")",
    "reservation_id": "$(json_escape "$RESERVATION_ID")",
    "iam_role": "$(json_escape "$IAM_ROLE")",
    "ec2_hostname": "$(json_escape "$HOSTNAME_AWS")",
    "ec2_public_hostname": "$(json_escape "$PUBLIC_HOSTNAME")"
  },
  "network": {
    "public_ipv4": "$(json_escape "$PUBLIC_IPV4")",
    "private_ipv4": "$(json_escape "$LOCAL_IPV4")"
  }
}
JSON

chmod 644 "$OUT"
echo "Wrote $OUT"
