# dkd-platform-libs  ·  v1.0.0

> **The reusable platform libraries every DOKANDAR repository consumes.** Everything here is
> **generated from the frozen `dkd-contracts-spine` v1.0.0** by a single canonical generator
> (`dkdgen`). The contracts are the only source of truth — this repo **consumes, never edits** them
> and **never fabricates** what the contracts defer. **Classification: Internal.**

## Contract philosophy

- **One generator, one contract model, five SDKs.** `dkdgen` parses the 10 frozen contracts into a
  single IR (`dkdgen.ir.Contracts`) and emits **Java, Go, TypeScript, Python, C# (.NET 8)** SDKs with
  **identical semantics**. Nothing is hand-duplicated across languages.
- **Freeze-verified input.** On every run the generator recomputes each contract's SHA-256 against
  `contracts/spine.lock.yaml` and refuses to generate on drift — this is the platform-libs side of
  *contract-compatibility verification*.
- **Generated / Framework-only / Blocked.** Anything the frozen contracts deterministically contain
  is **generated**. Anything they defer (`NEEDS-INFO`) — event payloads, JSON-Schemas, OpenAPI/proto,
  concrete error codes, the permission matrix — is emitted as a typed **extension point**
  (framework-only), **never fabricated**. See [`docs/architecture.md`](docs/architecture.md).

## Repository layout

```
generators/
  dkdgen/                  # the single canonical generator (Python)
    ir.py                  #   the one contract model (IR)
    contracts.py           #   parser + freeze-integrity verification
    version.py             #   generator + build provenance
    cli.py / __main__.py   #   `python -m dkdgen generate|verify`
    emitters/              #   base + python/java/go/typescript emitters
  tests/                   # generator unit + parser/IR tests
contracts/                 # PINNED snapshot of dkd-contracts-spine@v1.0.0 (consumed, never edited)
sdk/
  java/  go/  typescript/  python/  csharp/   # generated SDKs (committed; CI proves no drift)
ci/templates/governance.yml           # shared governance CI template
scripts/generate.sh                   # deterministic regeneration
docs/                                  # architecture, generator/SDK/versioning/release/dev/migration guides
examples/                             # per-language usage examples
VERSION                                # 1.0.0
```

## What each SDK contains (all generated from the contracts)

| Module | Source contract | Status |
|---|---|---|
| **ids** — strongly-typed `DID/PPID/GPID/ORD/TRD/WLT/ESC/TXN/SHP/NTF/MFSA` + `Money(int64 poisha)` + `Timestamp(int64 ms)` | `ids.yaml` | ✅ Generated |
| **topics/events** — 59 Kafka topic constants + per-topic metadata, 10 RabbitMQ queues, event envelope/headers | `messaging.yaml` | ✅ Generated (payloads → framework) |
| **config** — 5 canon-named constants (cooling-off, escrow TTL, NIL rollup, delivery lead, RPO) | `configuration.yaml` | ✅ Generated |
| **enums** — 7 families (KYC `V0–V3` exhaustive; others canon-named) | `glossary.yaml` | ✅ Generated |
| **errors** — `dokandar.<context>.<category>.<reason>` builder + 14 context slugs + ProblemDetails + exception hierarchy | `error-codes.yaml` | ✅ Generated (code list → framework) |
| **dto** — `Response{success,data,error,meta}`, cursor `Page`, trace/audit metadata | `api-registry.yaml` (EF §7) | ✅ Generated |
| **schema** — 59-subject registry + BACKWARD compatibility + version helpers | `schema-registry.yaml` | ✅ Generated (JSON-Schemas → framework) |
| **security** — role enums, access principles, JWT claim names, correlation/trace propagation | `permissions.yaml` | ✅ Generated (matrix → framework) |
| **validation** — id / money / envelope / topic validation | (cross-cutting) | ✅ Generated |

## Quick start

```bash
# regenerate every SDK from the frozen contracts (deterministic)
bash scripts/generate.sh all
# verify freeze integrity only
python3 -m dkdgen verify --contracts contracts
```

Consume an SDK: Python `pip install ./sdk/python` · Go `import ".../sdk/go"` · TS `npm i ./sdk/typescript`
· Java `mvn -f sdk/java install`. See [`docs/sdk-guide.md`](docs/sdk-guide.md).

## Versioning & provenance

SemVer; this release = **1.0.0** (matches contracts v1.0.0). Every generated file carries a banner
with **generator version, contract version, build time, build commit**. See
[`docs/versioning.md`](docs/versioning.md) and [`docs/release.md`](docs/release.md).

Trace: R6, R7, ADR-008, ADR-010, ADR-016, ADR-021
