#!/usr/bin/env bash
# =============================================================================
# DOKANDAR dev-infra — EXTRA secret generator for the compose.extra.yaml engines
# (Neo4j, TimescaleDB, ClickHouse, MongoDB). Same idempotent pattern as gen-secrets.sh:
# appends to ./.env.secrets ONLY for keys that are still empty. Usage: ./gen-secrets-extra.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
OUT=".env.secrets"

gen() { { command -v openssl >/dev/null 2>&1 && openssl rand -base64 36 || head -c 48 /dev/urandom | base64; } | tr -d '\n/+=' | cut -c1-40; }

declare -a KEYS=(NEO4J_PASSWORD TIMESCALE_PASSWORD CLICKHOUSE_PASSWORD MONGO_PASSWORD)

touch "$OUT"; chmod 600 "$OUT"

for k in "${KEYS[@]}"; do
  if grep -qE "^${k}=." "$OUT"; then
    echo "  $k: kept (already set)"
  else
    sed -i "/^${k}=/d" "$OUT"
    printf '%s=%s\n' "$k" "$(gen)" >> "$OUT"
    echo "  $k: generated"
  fi
done
echo "Extra secrets ready in $OUT."
