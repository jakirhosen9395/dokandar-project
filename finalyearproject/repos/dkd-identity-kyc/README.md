# dkd-identity-kyc

> Identity, Party & KYC — DOKANDAR platform. **Classification: Internal** · Data: **synthetic only** (ADR-024).
> **Status: skeleton (Stage 0.1).** Business logic arrives in **Stage 1** — this repo
> currently carries governance + CI baseline only, by design (incremental build, EF build order).

| Property | Value |
|---|---|
| Context | Bounded context #1 |
| Runtime | C#/.NET |
| Datastore (engine-of-record) | PostgreSQL (+ PII field-encryption) |
| Release tier | Standard |
| Enforcement | R7 |
| Owning team (FYP: single owner) | Substrate |

## What this repository is

Master-data OHS for DID; KYC tiers V0–V3; RBAC/ABAC PDP; owns all PII. No context forks DID (R7).

## Governance & authority

This repo realizes the **frozen** DOKANDAR canon and may never contradict it. Authority order:
**BA > DM > SYS > SA > EF > Roadmap > Accepted ADRs > Standards > Contracts**. Any conflict →
STOP and raise an ADR (never silently deviate — P1/P2/P3).

- Integration is **events / OHS only** — no context reads or writes another context's datastore (R6).
- Hexagonal layout: `domain ← application ← adapters` (domain imports nothing outward).
- Money = `int64` poisha; time = `int64` ms UTC; IDs = UUIDv7 (DM type conventions).
- Every change carries a `Trace:` anchor (BR-/FR-/R#/ADR-/SA-Ch.); orphan work is rejected.

See [`docs/architecture.md`](docs/architecture.md) for the target structure and the rules this
context must uphold.

## Build & Definition of Done

**The DoD is a green GitLab CI pipeline** (ADR-024). Local builds are optional. See
[`CONTRIBUTING.md`](CONTRIBUTING.md). Versioning is SemVer (see [`CHANGELOG.md`](CHANGELOG.md) /
[`VERSION`](VERSION)).

Trace: ADR-024, EF§2.3, R6, R-REPO-1
