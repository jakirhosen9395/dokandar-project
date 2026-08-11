#!/usr/bin/env bash
# data/cloud/collect.sh — writes data/cloud/result.json (served by GET /data when TENANT=cloud).
# 14-notification (Node 24 / Fastify 5) EC2 metadata + baseline + a static service-shape block.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; OUT="${SCRIPT_DIR}/result.json"
read_os_pretty_name() { if [ -f /etc/os-release ]; then . /etc/os-release; printf '%s' "${PRETTY_NAME:-${ID:-unknown}}"; else printf 'unknown'; fi; }
json_escape() { local s="${1-}"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/\\r}"; s="${s//$'\n'/\\n}"; printf '%s' "$s"; }
safe() { local v="${1-}"; if [ -z "$v" ] || echo "$v" | grep -Eiq "^[[:space:]]*$|404|not found"; then printf '%s' "${2:-unavailable}"; else printf '%s' "$v"; fi; }
TOKEN="$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' 2>/dev/null || true)"
meta() { if [ -n "$TOKEN" ]; then curl -s -m 2 -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || true; else curl -s -m 2 "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || true; fi; }
dyn()  { if [ -n "$TOKEN" ]; then curl -s -m 2 -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/dynamic/$1" 2>/dev/null || true; else curl -s -m 2 "http://169.254.169.254/latest/dynamic/$1" 2>/dev/null || true; fi; }
HOSTNAME_VAL="$(hostname 2>/dev/null || echo unknown)"; OS_PRETTY="$(read_os_pretty_name)"; KERNEL="$(uname -r 2>/dev/null || echo unknown)"; ARCH="$(uname -m 2>/dev/null || echo unknown)"
UPTIME_PRETTY="$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo unknown)"; NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CPU_MODEL="$(awk -F: '/model name/ {sub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"; [ -z "$CPU_MODEL" ] && CPU_MODEL="unknown"
CPU_CORES="$(nproc 2>/dev/null || echo unknown)"; CPU_LOAD="$(safe "$(uptime 2>/dev/null | awk -F'load average:' '{gsub(/^ +/, "", $2); print $2}')" unknown)"
MEM_TOTAL="$(safe "$(free -h 2>/dev/null | awk '/Mem:/ {print $2}')" unknown)"; MEM_USED="$(safe "$(free -h 2>/dev/null | awk '/Mem:/ {print $3}')" unknown)"; MEM_AVAILABLE="$(safe "$(free -h 2>/dev/null | awk '/Mem:/ {print $7}')" unknown)"
DISK_TOTAL="$(safe "$(df -h / 2>/dev/null | awk 'NR==2 {print $2}')" unknown)"; DISK_USED="$(safe "$(df -h / 2>/dev/null | awk 'NR==2 {print $3}')" unknown)"; DISK_FREE="$(safe "$(df -h / 2>/dev/null | awk 'NR==2 {print $4}')" unknown)"; DISK_PCT="$(safe "$(df -h / 2>/dev/null | awk 'NR==2 {print $5}')" unknown)"
INSTANCE_ID="$(safe "$(meta instance-id)" unavailable)"; INSTANCE_TYPE="$(safe "$(meta instance-type)" unavailable)"; AMI_ID="$(safe "$(meta ami-id)" unavailable)"
PUBLIC_IPV4="$(safe "$(meta public-ipv4)" unavailable)"; LOCAL_IPV4="$(safe "$(meta local-ipv4)" unavailable)"
AVAILABILITY_ZONE="$(safe "$(meta placement/availability-zone)" unavailable)"; REGION="$(safe "$(dyn instance-identity/document | awk -F'\"' '/region/ {print $4}')" unavailable)"; IAM_ROLE="$(safe "$(meta iam/security-credentials/)" "no IAM role attached")"
case "$CPU_CORES" in ''|*[!0-9]*) CPU_CORES_JSON="\"$(json_escape "$CPU_CORES")\"" ;; *) CPU_CORES_JSON="$CPU_CORES" ;; esac
cat > "$OUT" <<JSON
{
  "kind": "cloud",
  "provider": "aws-ec2",
  "service": "14-notification",
  "collected_at": "$(json_escape "$NOW_UTC")",
  "notification": {
    "language": "Node.js 24 / Fastify 5",
    "service_port": 3000,
    "external_rest": 10014,
    "grpc": "none (exposes none, calls none)",
    "role": "terminal consumer — event-to-user fan-out; emits nothing, no outbox",
    "datastores": { "inbox": "MongoDB 8.3", "dedup_ws_routing": "Redis DB 10", "ws_subjects": "NATS JetStream", "log_sink_es": "APM-stack Elasticsearch :9200" },
    "ready_gate": "MongoDB only (Redis/Kafka/RabbitMQ/NATS degradable, not gating)",
    "channels": ["sms", "whatsapp", "push", "email"],
    "channel_providers": { "sms": "SSL Wireless", "whatsapp": "WhatsApp Business Cloud", "push": "FCM", "email": "Amazon SES" },
    "mongo_collections": ["notifications", "notification_preferences", "notification_dispatch_log"],
    "consumes_kafka": ["dokandar.user.created", "dokandar.order.placed", "dokandar.payment.settled", "dokandar.kyc.approved", "dokandar.kyc.rejected", "dokandar.wallet.cashback_granted"],
    "rabbitmq_queues": ["notifications.email", "notifications.sms", "notifications.push", "notifications.whatsapp_deeplink", "notifications.otp.send"],
    "emits_kafka": []
  },
  "host": { "hostname": "$(json_escape "$HOSTNAME_VAL")", "os": "$(json_escape "$OS_PRETTY")", "kernel": "$(json_escape "$KERNEL")", "architecture": "$(json_escape "$ARCH")", "uptime": "$(json_escape "$UPTIME_PRETTY")" },
  "cpu": { "model": "$(json_escape "$CPU_MODEL")", "cores": ${CPU_CORES_JSON}, "load_average": "$(json_escape "$CPU_LOAD")" },
  "memory": { "total": "$(json_escape "$MEM_TOTAL")", "used": "$(json_escape "$MEM_USED")", "available": "$(json_escape "$MEM_AVAILABLE")" },
  "storage": { "root_total": "$(json_escape "$DISK_TOTAL")", "root_used": "$(json_escape "$DISK_USED")", "root_free": "$(json_escape "$DISK_FREE")", "root_usage_percent": "$(json_escape "$DISK_PCT")" },
  "ec2": { "instance_id": "$(json_escape "$INSTANCE_ID")", "instance_type": "$(json_escape "$INSTANCE_TYPE")", "ami_id": "$(json_escape "$AMI_ID")", "region": "$(json_escape "$REGION")", "availability_zone": "$(json_escape "$AVAILABILITY_ZONE")", "iam_role": "$(json_escape "$IAM_ROLE")" },
  "network": { "public_ipv4": "$(json_escape "$PUBLIC_IPV4")", "private_ipv4": "$(json_escape "$LOCAL_IPV4")" }
}
JSON
chmod 644 "$OUT"; echo "Wrote $OUT"
