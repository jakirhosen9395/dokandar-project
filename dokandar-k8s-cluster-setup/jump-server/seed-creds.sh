#!/usr/bin/env bash
# Copy the unified infra creds file into every backend service's expected location
# (env/components-creds.txt) so that init-env.sh scripts which do not honour the
# $CREDS_FILE env var still find the credentials they need.
# Run this BEFORE render-envs.sh when working from the jump-server workspace.
#
# Usage: CREDS=<path-to-infra-creds.txt> BACKEND=<path-to-backend/> bash seed-creds.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CREDS="${CREDS:-$HERE/../../creds/infra-creds.txt}"
BACKEND="${BACKEND:-$HERE/../../../backend}"

[ -f "$CREDS" ] || { echo "ERROR: $CREDS not found"; exit 1; }

for svc in 00-support 02-profile 03-seller 04-catalog 05-search 06-cart 07-coupon \
           08-review 09-payment 10-wallet 11-reporting 12-media 13-order \
           14-notification 15-api-gateway 16-recommendation 17-shipping 18-risk-trust; do
  dest="$BACKEND/$svc/env/components-creds.txt"
  if [ -d "$BACKEND/$svc/env" ]; then
    cp "$CREDS" "$dest"
    echo "  seeded $svc/env/components-creds.txt"
  else
    echo "  WARN: $BACKEND/$svc/env not found — skipping"
  fi
done
echo "Done seeding creds for $(ls -d "$BACKEND"/[0-9][0-9]-*/env/components-creds.txt 2>/dev/null | wc -l) services"
