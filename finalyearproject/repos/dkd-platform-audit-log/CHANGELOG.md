# Changelog

All notable changes to audit-log-svc. Trace: R6, ADR-024, W1.

## [0.1.0] - 2026-07-02
### Added
- Initial **audit-log-svc** (Context #13 Platform) — append-only OHS audit sink (R6).
- **franz-go** consumer over the full Kafka spine (`dkdplatform.AllTopics()`); the platform's first real
  Kafka client. Never produces (R6); never auto-creates topics (CORRECTION 2).
- **Append-only WORM store** (pgx/Postgres, `dkd_platform`) with **inbox dedup on `event_id`**
  (effectively-once); UPDATE/DELETE rejected by a reject-trigger + REVOKE.
- **PII producer-contract guard** — always append + quarantine-copy + metric on PII-shaped fields
  (CORRECTION 1); never drops/rejects.
- Dead-letter **park-and-freeze** for poison messages.
- `/health` `/live` `/ready` (green only after Kafka + DB) `/version` (single-source provenance) plus a
  hand-rolled OpenAPI surface (`/docs`, `/swagger/v1/swagger.json`, Bearer).
- dkd-platform SDK **vendored byte-identically at v1.3.0**.
