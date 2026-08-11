# Developer Guide

## Prerequisites

- Python 3.10+ (`pyyaml`, `pytest`) for the generator
- Per SDK you touch: Go 1.22 · JDK 17 + Maven · Node 20 (TypeScript)

## Local loop

```bash
# 1. verify the frozen contracts
python3 -m dkdgen verify --contracts contracts
# 2. run generator + parser tests
cd generators && python3 -m pytest tests/ -q && cd ..
# 3. regenerate every SDK (deterministic)
bash scripts/generate.sh all
# 4. build/test an SDK
cd sdk/python && python3 -m pytest tests/ -q
cd sdk/go && go test ./...
cd sdk/typescript && npm install && npm run build && npm test
cd sdk/java && mvn -B test
```

## Golden rule

**Never hand-edit anything under `sdk/`** — it is generator-owned (the drift gate fails on manual
edits). To change an SDK, change the generator (`generators/dkdgen/`) and regenerate. To change a
contract value, that is a `dkd-contracts-spine` change (additive ADR; this repo only consumes).

## Where to change what

| Want to change… | Edit |
|---|---|
| A derived name / artifact across all SDKs | `generators/dkdgen/emitters/*` (+ regenerate) |
| The contract model (new field) | `generators/dkdgen/ir.py` + `contracts.py` (+ emitters) |
| A contract value | upstream `dkd-contracts-spine` (additive ADR), then sync `contracts/` |

## CI parity

`scripts/generate.sh` is exactly what CI runs; if it is clean locally, the drift gate passes.
