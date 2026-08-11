# dkd-contracts-spine  ·  v1.0.0 (FROZEN)

> **The canonical Published Language for DOKANDAR** — machine-readable contracts derived verbatim
> from the frozen architecture. Every future repository (platform libraries, the 13 context
> services, edge/BFFs, CI, code generators) depends on this repo. **Classification: Internal.**
> The event spine is the ONLY legal cross-context channel (R6).

## Contract philosophy

- **Single source of truth.** Contracts are derived ONLY from the frozen L0 canon and cite it by ID.
  Nothing is invented here; anything not verbatim in canon is explicitly marked **NEEDS-INFO**
  (Phase-2 transcription) — never fabricated (P2).
- **Frozen + versioned.** The spine is frozen at **v1.0.0** via `spine.lock.yaml` (a per-file sha256
  manifest). Any byte change to a frozen contract is caught by CI (freeze-drift) — change-by-ADR only.
- **CI is the gate.** `tools/validate_contracts.py` enforces every invariant on every pipeline; a
  violation fails the build. Local == CI.

## Directory layout

| File | Purpose | Authority |
|---|---|---|
| `messaging.yaml` | 59 Kafka topics + 10 RabbitMQ intra-context queues | DM Kafka Catalog; ADR-016 |
| `data-stores.yaml` | 13 per-context persistence services + 3 unreconciled variants | SYS §8.1; ADR-017 |
| `ids.yaml` | Canonical identifier + type registry (DID/PPID/GPID/…, money/time/uuid) | DM Type Conventions |
| `api-registry.yaml` | API planes (REST /v1, gRPC OHS) + published Open-Host Services | EF §7; ADR-008 |
| `schema-registry.yaml` | One schema subject per Kafka topic + compatibility policy | EF §8.4; ADR-010 |
| `permissions.yaml` | Access principles (R1/R2/R4/R5/R7) + role families | BA; enum-registry |
| `configuration.yaml` | Canon-named operational constants (cooling-off, TTLs, RPO, rollup) | DM; SA Ch.27 |
| `error-codes.yaml` | RFC-7807 `dokandar.<context>.<category>.<reason>` taxonomy | EF §7.7 |
| `glossary.yaml` | Machine companion to the FR-IDN-310 enum doc-of-record | FR-IDN-310; ADR-018 |
| `enum-registry.md` | FR-IDN-310 enum/actor doc-of-record (prose; values NEEDS-INFO) | FR-IDN-310; ADR-018 |
| `spine.lock.yaml` | **Freeze manifest** — pins the spine at v1.0.0 with per-file sha256 | this repo |
| `tools/validate_contracts.py` | The contract validator (run in CI) | — |

## Validation (`tools/validate_contracts.py`)

Enforces (fails fast, clear messages): YAML validity · ADR-021 header-profile compliance · SemVer ·
topic grammar + 59-count + ordering keys + R1 custody sole-writer + ADR-016 no-errata · R6 Kafka/
RabbitMQ split · ADR-017 unreconciled engines not adopted + R1/R2 isolation · duplicate IDs/topics/
subjects/codes/families · schema subjects == Kafka topics · OHS owner contexts valid · error-code
grammar + valid context · referential integrity (producer/consumer ↔ data-stores) · **freeze-lock
integrity** (sha256 drift) + VERSION consistency.

Run locally: `python3 tools/validate_contracts.py` (needs `pyyaml`).

## How future repositories consume these contracts

- **Versioned artifact, never shared source (R6).** Consumers pin a spine version (this freeze =
  `v1.0.0`) and import the registries; they never copy or fork a contract.
- Code generators read `ids.yaml` / `schema-registry.yaml` / `messaging.yaml` to emit per-language
  types, event clients, and topic constants (Phase 2).
- A breaking change to any contract is a **new major + a new `.vN` topic** where applicable — never
  an in-place edit (R6); the freeze lock makes drift a CI failure.

## Contribution workflow

`main` is protected (MR-only). Branch `feat/...`, Conventional Commits with a `Trace:` footer, MR →
green pipeline → fast-forward merge. SemVer; money/contract/ordering-key changes force MAJOR.
Four-eyes is relaxed to single-author for the FYP (ADR-024) but the MR + CODEOWNERS topology is kept.

Trace: R6, R7, ADR-008, ADR-010, ADR-016, ADR-017, ADR-018, ADR-021
