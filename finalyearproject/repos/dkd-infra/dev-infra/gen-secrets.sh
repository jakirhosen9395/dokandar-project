#!/usr/bin/env bash
# =============================================================================
# DOKANDAR dev-infra — secret generator.  Writes ./.env.secrets (gitignored) with strong, random
# credentials, ONLY for keys that are still empty (idempotent — re-running never overwrites a set value).
# Secrets are kept OUT of .env (config) so the split maps cleanly to Kubernetes Secret vs ConfigMap.
# Pattern reused from the utilities repo (openssl rand). Usage:  ./gen-secrets.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
OUT=".env.secrets"

gen() { { command -v openssl >/dev/null 2>&1 && openssl rand -base64 36 || head -c 48 /dev/urandom | base64; } | tr -d '\n/+=' | cut -c1-40; }

declare -a KEYS=(POSTGRES_PASSWORD REDIS_PASSWORD RABBITMQ_DEFAULT_PASS RUSTFS_ACCESS_KEY RUSTFS_SECRET_KEY APM_SECRET_TOKEN)

touch "$OUT"; chmod 600 "$OUT"
[ -s "$OUT" ] || printf '# DOKANDAR dev-infra SECRETS — generated, gitignored. Do NOT commit. -> Kubernetes Secret.\n' > "$OUT"

for k in "${KEYS[@]}"; do
  if grep -qE "^${k}=." "$OUT"; then
    echo "  $k: kept (already set)"
  else
    v="$(gen)"
    # remove any empty placeholder then append
    sed -i "/^${k}=/d" "$OUT"
    printf '%s=%s\n' "$k" "$v" >> "$OUT"
    echo "  $k: generated"
  fi
done
echo "Secrets ready in $OUT (chmod 600, gitignored)."
