#!/usr/bin/env bash
# Regenerate every SDK from the frozen contracts. The contracts are the only source of truth;
# this script never edits them. CI runs the same command and asserts the working tree is unchanged
# (generator-drift gate).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTRACTS="${DKD_CONTRACTS_DIR:-$ROOT/contracts}"
OUT="$ROOT/sdk"

export DKDGEN_BUILD_TIME="${DKDGEN_BUILD_TIME:-2026-06-29T00:00:00Z}"   # deterministic by default (freeze date)
export DKDGEN_BUILD_COMMIT="${DKDGEN_BUILD_COMMIT:-source}"             # stable marker for committed source

cd "$ROOT/generators"
python3 -m dkdgen verify --contracts "$CONTRACTS"
python3 -m dkdgen generate --lang "${1:-all}" --contracts "$CONTRACTS" --out "$OUT"
echo "OK — SDKs regenerated from contracts (deterministic build_time=$DKDGEN_BUILD_TIME)"
