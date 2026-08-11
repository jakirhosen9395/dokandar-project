# Changelog
All notable changes to **dkd-contracts-spine** are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning: [SemVer](https://semver.org/).

## [1.0.0] — 2026-06-29  ·  Phase 1 FREEZE
### Added
- Seven derived Published-Language contracts (canon-traced; NEEDS-INFO for un-transcribed values):
  `ids.yaml`, `api-registry.yaml`, `schema-registry.yaml` (59 subjects = 59 topics),
  `permissions.yaml`, `configuration.yaml`, `error-codes.yaml`, `glossary.yaml`.
- `spine.lock.yaml` — freeze manifest (per-file sha256) pinning the spine bundle at **v1.0.0**.
- Validator extended: ADR-021 header-profile + SemVer, ids/schema/api/permissions/config/error/
  glossary checks, duplicate-ID/topic/subject/code/family checks, schema-subjects==topics,
  referential integrity, and **freeze-lock integrity** (drift detection).
### Changed
- Spine version 0.1.0 → **1.0.0** (FROZEN). `messaging.yaml`/`data-stores.yaml`/`enum-registry.md`
  remain verbatim transcriptions of frozen canon (own 0.1.0 lifecycle); the spine bundle is 1.0.0.

## [0.1.0] — 2026-06-29
### Added
- Published canonical contracts verbatim (messaging/data-stores/enum) + CI contract validator.

## [0.0.0] — 2026-06-29
### Added
- Stage 0.1 repository skeleton and governance baseline.

Trace: ADR-016, ADR-017, ADR-018, ADR-021
