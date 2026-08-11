#!/usr/bin/env bash
# setup_env.sh — create/complete this variant's .env (idempotent; safe to re-run).
#   1. copies .env.example -> .env when .env is missing
#   2. generates a strong 24-char password for every EMPTY *_PASSWORD variable
#   3. chmod 600 .env and prints what it did (values are never echoed)
set -euo pipefail
cd "$(dirname "$0")"

gen_password() { { command -v openssl >/dev/null && openssl rand -base64 48 || head -c 256 /dev/urandom; } \
  | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24; }

if [ ! -f .env ]; then
  cp .env.example .env
  echo "created .env from .env.example"
else
  echo ".env already exists — keeping existing values"
fi

# Fill every *_PASSWORD= that is empty; leave non-empty ones untouched (idempotent).
while IFS= read -r key; do
  if grep -qE "^${key}=$" .env; then
    sed -i "s|^${key}=$|${key}=$(gen_password)|" .env
    echo "generated ${key} (24 chars, saved to .env)"
  else
    echo "${key} already set — reused"
  fi
done < <(grep -oE '^[A-Z0-9_]*PASSWORD[A-Z0-9_]*' .env.example | sort -u)

chmod 600 .env
echo ".env is ready (chmod 600). Next:  bash setup.sh up"

# --- SERVER_IP autofill -------------------------------------------------------
# Fill SERVER_IP when empty so printed endpoints use THIS box's PRIVATE (VPC) IP:
# EC2 metadata local-ipv4 (IMDSv2) -> first local IP. Idempotent.
if grep -qE '^SERVER_IP=$' .env; then
  TOK="$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
  PUB="$(curl -s -m 2 -H "X-aws-ec2-metadata-token: ${TOK}" http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || true)"
  case "$PUB" in *[!0-9.]*) PUB="";; esac
  [ -n "$PUB" ] || PUB="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [ -n "$PUB" ]; then
    sed -i "s|^SERVER_IP=$|SERVER_IP=${PUB}|" .env
    echo "detected SERVER_IP=${PUB} (private IP — used for the printed endpoints)"
  fi
fi

# --- Kafka-specific autofill ----------------------------------------------------
# KRaft needs a cluster id before compose can even PARSE the file (CLUSTER_ID uses
# :? interpolation), and the broker must advertise a host clients can reach.
# Both are generated once and reused forever (idempotent).
if grep -qE '^KAFKA_CLUSTER_ID=$' .env; then
  KV="$(grep -E '^KAFKA_VERSION=' .env | cut -d= -f2 || true)"
  CID="$(docker run --rm "apache/kafka:${KV:-4.3.0}" /opt/kafka/bin/kafka-storage.sh random-uuid 2>/dev/null | tr -d '\r' || true)"
  if [ -n "$CID" ]; then
    sed -i "s|^KAFKA_CLUSTER_ID=$|KAFKA_CLUSTER_ID=${CID}|" .env
    echo "generated KAFKA_CLUSTER_ID (KRaft storage uuid)"
  else
    echo "! could not generate KAFKA_CLUSTER_ID (docker unavailable?) — setup.sh up will retry"
  fi
fi
if grep -qE '^KAFKA_EXTERNAL_HOST=$' .env; then
  SIP="$(grep -E '^SERVER_IP=' .env | cut -d= -f2 || true)"
  [ -n "$SIP" ] && { sed -i "s|^KAFKA_EXTERNAL_HOST=$|KAFKA_EXTERNAL_HOST=${SIP}|" .env; echo "advertised host = ${SIP}"; }
fi
