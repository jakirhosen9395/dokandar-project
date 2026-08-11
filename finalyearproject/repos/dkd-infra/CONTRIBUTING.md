# Contributing — dkd-infra

## Workflow (MR-only)
- `main` is protected; **no direct pushes**. All changes via Merge Request.
- Branch names: `feat/<context>-<ticket>-<slug>` / `fix/...` / `chore/...`.
- **Conventional Commits** required (CI-enforced): `feat|fix|chore|docs|refactor|test|ci|perf|build|revert`.
  Use `feat!` / `BREAKING CHANGE:` when a Published-Language schema or OHS contract changes.
- Every commit / MR carries a **`Trace:`** footer with a canonical ID (P1 traceability).

## Definition of Done
The DoD is a **green GitLab CI pipeline** (ADR-024) + the MR checklist. Local builds optional;
GitLab CI is the canonical validation environment.

## Versioning
**SemVer** (`VERSION` + `CHANGELOG.md`, Keep-a-Changelog). Money/contract/ordering-key changes force MAJOR.

## Four-eyes (R4)
Relaxed to single-author self-approval for the FYP (ADR-024 §3). The MR + CODEOWNERS topology is kept
so the four-eyes process is demonstrable and re-armable for production.

Trace: ADR-024, EF§15 (git workflow), R4
