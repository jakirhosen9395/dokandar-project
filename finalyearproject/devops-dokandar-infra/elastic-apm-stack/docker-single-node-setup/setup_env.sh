#!/usr/bin/env bash
# setup_env.sh — create/complete this variant's .env (idempotent; safe to re-run).
# Generates the FOUR stack secrets; KIBANA_ENCRYPTION_KEY is exactly 32 chars.
set -euo pipefail
cd "$(dirname "$0")"

gen() { { command -v openssl >/dev/null && openssl rand -base64 48 || head -c 256 /dev/urandom; } \
  | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"$1"; }

if [ ! -f .env ]; then cp .env.example .env; echo "created .env from .env.example"
else echo ".env already exists — keeping existing values"; fi

fill() { local k="$1" n="$2"
  if grep -qE "^${k}=$" .env; then
    sed -i "s|^${k}=$|${k}=$(gen "$n")|" .env; echo "generated ${k} (${n} chars)"
  else echo "${k} already set — reused"; fi; }

fill ELASTIC_PASSWORD 24
fill KIBANA_PASSWORD 24
fill KIBANA_ENCRYPTION_KEY 32
fill APM_SECRET_TOKEN 32

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
