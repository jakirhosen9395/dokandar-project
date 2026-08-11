# Versioning Guide

## Scheme

- **SemVer.** This repo starts at **1.0.0** and tracks the contract baseline it generates from
  (`dkd-contracts-spine` v1.0.0).
- **The contract version drives the SDK version.** A new contracts release regenerates the SDKs and
  bumps platform-libs accordingly:
  - contracts **MAJOR** (breaking PL change) → platform-libs **MAJOR**
  - contracts **MINOR** (additive: populated `NEEDS-INFO`, new topic `.vN`, new enum value) → platform-libs **MINOR**
  - generator-only fix (no contract change) → platform-libs **PATCH**

## Provenance in every artifact

Each generated file carries: `generator`, `generator_version`, `contract_version`, `build_time`,
`build_commit`. The `_provenance` module of each SDK exposes `CONTRACT_VERSION` / `GENERATOR_VERSION`
at runtime.

## Compatibility

Event schemas are **BACKWARD-compatible within a major** (EF §8.4); a breaking change is a new `.vN`
topic, never an in-place edit (R6). The `schema` module exposes `is_compatible(new, old)` and the
per-subject `Compatibility` policy.

## Determinism

Committed SDK source uses fixed provenance defaults so the **generator-drift gate** can assert
`committed == regenerated`. Live timestamp/commit are stamped only on published artifacts.
