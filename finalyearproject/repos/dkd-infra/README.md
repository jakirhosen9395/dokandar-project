# dkd-infra

> Sovereign Landing Zone & Platform IaC — DOKANDAR platform. **Classification: Internal** · Data: **synthetic only** (ADR-024).
> **Status: skeleton (Stage 0.1).** Business logic arrives in **Stage 0** — this repo
> currently carries governance + CI baseline only, by design (incremental build, EF build order).

| Property | Value |
|---|---|
| Context | Infra |
| Runtime | IaC (Terraform / Helm / k8s) |
| Datastore (engine-of-record) | — |
| Release tier | Standard |
| Enforcement | R2, R6 |
| Owning team (FYP: single owner) | Platform/SRE |

## What this repository is

Landing-zone / Kubernetes namespace topology, CI runners, registry IaC (reserved prefix dkd-infra-*, EF §2.3). No manifests yet (Stage 0.5); skeleton only now.

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
