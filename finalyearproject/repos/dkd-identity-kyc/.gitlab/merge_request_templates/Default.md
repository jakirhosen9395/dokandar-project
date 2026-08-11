## Summary
<what changed and why — one logical concern, ≤ ~400 lines>

## Trace
Trace: <BR-/FR-/R#/ADR-/SA-Ch.>   <!-- MANDATORY: orphan work is rejected (P1) -->

## Definition of Done (EF §17.2 — FYP-tiered per ADR-024)
- [ ] Conventional Commit title (feat/fix/chore/docs/refactor/test/ci/perf/build/revert)
- [ ] Tests added/updated; **pipeline green** (DoD = green CI)
- [ ] Hexagonal layout respected (domain ← application ← adapters); no outward domain imports
- [ ] No cross-context DB access — integration via events / OHS only (R6)
- [ ] No business rule invented (P2); money = int64 poisha where applicable
- [ ] Docs / CHANGELOG updated; SemVer impact noted (`feat!`/`BREAKING CHANGE:` on contract change)
- [ ] Four-eyes: relaxed to self-approval for the FYP (ADR-024 §3); topology still via MR + CODEOWNERS

/assign me
