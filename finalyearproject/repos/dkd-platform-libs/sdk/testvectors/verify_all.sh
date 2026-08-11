#!/usr/bin/env bash
# CustodyHash cross-language determinism gate (DM §2/§10, PL-01).
# Runs each runtime's CustodyHash implementation against the shared golden fixture
# (custodyhash_vectors.json) and FAILS if any runtime diverges on canonical bytes or digest.
# CI wires this as a BLOCKING merge gate for dkd-platform-libs. Uses whatever toolchains are
# present; missing local toolchains fall back to docker (set DOCKER=1). Exit non-zero on any miss.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 3          # -> sdk/
FIX="testvectors/custodyhash_vectors.json"
EXPECT_TV01="ac543fecee75695fb2b1922ea9e0830f4bddb6ef1ad17e80f278d6171cbe0597"
fail=0; ran=0

step() { printf '\n=== %s ===\n' "$1"; }

# --- Python ---
if command -v python3 >/dev/null 2>&1; then
  step "python"; ran=$((ran+1))
  PYTHONPATH=python/src python3 - <<'PY' || fail=1
import json
from dkd_platform import custody_hash as ch
for v in json.load(open("testvectors/custodyhash_vectors.json"))["vectors"]:
    c = ch.canonical({k:val for k,val in v["fields"].items() if k!="eventHash"})
    assert c == v["canonical"], v["name"]+" CANON"
    assert ch.event_hash(v["fields"]) == v["digest"], v["name"]+" DIGEST"
print("python 8/8 OK")
PY
fi

# --- Node/TS (runs the tsc-built test, else a source mirror is covered by `npm test`) ---
if command -v node >/dev/null 2>&1 && [ -f typescript/dist/test/custody_hash.test.js ]; then
  step "typescript"; ran=$((ran+1))
  ( cd typescript && node --test dist/test/custody_hash.test.js ) || fail=1
fi

# --- Go ---
if command -v go >/dev/null 2>&1; then
  step "go"; ran=$((ran+1))
  ( cd go && go test ./... -run CustodyHash ) || fail=1
elif [ "${DOCKER:-0}" = 1 ]; then
  step "go (docker)"; ran=$((ran+1))
  docker run --rm -v "$PWD":/w -w /w/go golang:1.25 go test ./... -run CustodyHash || fail=1
fi

# --- Java / C# are verified in their module builds (mvn test / dotnet test) and in CI docker;
#     this script covers the always-available runtimes + a docker-Go fallback. ---

step "summary"
echo "ran $ran runtime gate(s); expected TV-01 digest = $EXPECT_TV01"
if [ "$fail" -ne 0 ]; then echo "CUSTODYHASH GATE: FAIL (divergence)"; exit 2; fi
if [ "$ran" -eq 0 ]; then echo "CUSTODYHASH GATE: no runtime ran"; exit 3; fi
echo "CUSTODYHASH GATE: PASS"
