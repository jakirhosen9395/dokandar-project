# Contributing — audit-log-svc

Trace: ADR-024, R6, W1.

- **Trunk-based:** short-lived `feat/platform-audit-<ticket>-<slug>` branches off protected `main`; MR-only.
- **Conventional Commits.** The MR **title** becomes the squash commit subject — CI enforces the format
  (`governance:mr-title-conventional`).
- **Merge gate = green pipeline** (governance + `go:build-test` + `test:integration`).
  `only_allow_merge_if_pipeline_succeeds` is on; nothing is committed directly to `main`.
- This service is the R6 OHS **audit sink**: it CONSUMES the spine and appends to a WORM store. It
  **never produces events**, **never creates topics**, and **never mutates or deletes audit rows**.
- **PII:** must never be produced onto the spine (producer contract). The sink flags-and-quarantines a
  PII-shaped payload and still appends it — it never drops or rejects. Synthetic data only (ADR-024).
- The dkd-platform SDK is **vendored byte-identically at v1.3.0** (`sdk/dkdplatform`, `replace` directive);
  do not bump it without a deliberate protocol amendment.
