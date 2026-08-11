#!/usr/bin/env bash
# Render per-service env files from the infra creds captured by the data-tier role.
# Reads .creds/infra-creds.txt (fetched from the infra host), writes .envs/<svc>.env.
# 01-auth is rendered FIRST (it mints the RS256 keypair + internal token); those are
# folded into an Auth_Identity block for every other service. Temporal is added too.
# GW_IP (api-gateway private IP) is passed in by the playbook for the frontend env.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# All paths overridable via env so this runs from the jump-server workspace too.
BACKEND="${BACKEND:-$HERE/../../../backend}"
CREDS="${CREDS:-$HERE/../../02-platform-setup/ansible/.creds/infra-creds.txt}"
OUT="${ENVS_OUT:-$HERE/.envs}"; rm -rf "$OUT"; mkdir -p "$OUT"
SUP=/tmp/dokandar-superset.txt

[ -f "$CREDS" ] || { echo "ERROR: $CREDS not found (run the data-tier play first)"; exit 1; }
INFRA_IP="$(grep -m1 -oE '[0-9.]+:5432' "$CREDS" | cut -d: -f1)"
GW_IP="${GW_IP:-127.0.0.1}"

awk '/^###/{f=1} f' "$CREDS" > "$SUP"
grep -qi '16_Temporal' "$SUP" || printf '\n### 16_Temporal\n   grpc           %s:7233\n   web-ui         http://%s:8233\n   auth           none\n' "$INFRA_IP" "$INFRA_IP" >> "$SUP"

cd "$BACKEND/01-auth" && CREDS_FILE="$SUP" bash env/init-env.sh .env.dev >/dev/null
cp env/.env.dev "$OUT/01-auth.env"
PUB="$(grep '^JWT_PUBLIC_KEY_B64=' env/.env.dev | cut -d= -f2-)"
TOK="$(grep '^INTERNAL_SERVICE_TOKEN=' env/.env.dev | cut -d= -f2-)"
printf '\n### Auth_Identity\n   auth_service_public_key   %s\n   internal_service_token    %s\n' "$PUB" "$TOK" >> "$SUP"

for d in 00-support 02-profile 03-seller 04-catalog 05-search 06-cart 07-coupon 08-review \
         09-payment 10-wallet 11-reporting 12-media 13-order 14-notification 15-api-gateway \
         16-recommendation 17-shipping 18-risk-trust; do
  if cd "$BACKEND/$d" && CREDS_FILE="$SUP" bash env/init-env.sh .env.dev >/dev/null 2>&1; then
    cp env/.env.dev "$OUT/$d.env"
  else echo "WARN: render failed for $d"; fi
done

cat > "$OUT/frontend.env" <<EOF
GATEWAY_URL=http://${GW_IP}:10015
SPEC_HOST=${GW_IP}
SESSION_COOKIE_SECRET=$(openssl rand -hex 32)
APP_ENV=dev
NEXT_PUBLIC_ENV=dev
NEXT_PUBLIC_DEFAULT_LOCALE=en
NEXT_PUBLIC_RUM_SERVICE_NAME=dokandar-web
EOF
echo "rendered $(ls "$OUT" | wc -l) env files into $OUT (infra=$INFRA_IP gw=$GW_IP)"
