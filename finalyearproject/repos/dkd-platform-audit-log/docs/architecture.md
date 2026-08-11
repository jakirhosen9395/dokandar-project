# audit-log-svc — Architecture

Trace: R6, ADR-024, W1, DOKANDAR-Domain-Model.md (event spine), DOKANDAR-Service-Architecture.md #13.

## Role
Context #13 Platform, the **append-only OHS audit sink**. Every cross-context event on the Kafka
Published Language (R6) is mirrored here into a WORM store — the durable audit of record. Governance and
compliance read this projection; the sink itself only consumes.

## Hexagonal layers (domain ← application ← adapters)
- `internal/audit` — pure domain: the append-only `Record` value object + the PII guard (`ScanPII`).
- `internal/consumer` — inbound adapter: franz-go consumer group over the spine; resolves the dedup
  `event_id`; parks poison to the DLQ. **Never produces; never auto-creates topics.**
- `internal/store` — outbound adapter: pgx WORM store; inbox dedup; quarantine + DLQ tables; migrations.
- `internal/ingest` — application use-case: build record → append (dedup) → on PII, quarantine + meter.
- `internal/httpx` — health/ready/version + hand-rolled OpenAPI. `internal/obs` — logging/metrics/tracing.
- `internal/app` — DI wiring; `/ready` flips true only after DB + Kafka are connected.

## Invariants
- **R6:** consume-only; integrate solely via the Kafka spine; one context = one Postgres (`dkd_platform`).
- **WORM:** `audit_log` is append-only (reject-trigger + `REVOKE UPDATE, DELETE`).
- **Effectively-once:** at-least-once Kafka delivery + inbox dedup on `event_id`.
- **CORRECTION 1 (PII):** always append + flag + quarantine-copy + metric; never drop/reject.
- **CORRECTION 2 (topics):** never create topics; tolerate missing (franz-go attaches on metadata refresh).
- **Provenance:** single-source SHA/version/build-time (one build-arg set → ldflags + OCI labels).

## Data model (`migrations/0001_init.sql`)
- `audit_log(event_id UNIQUE, topic, event_key, kafka_partition, kafka_offset, payload, ingested_at_ms,
  pii_flagged, pii_fields, persisted_at)` — append-only WORM.
- `audit_pii_quarantine`, `audit_dlq`, `schema_migrations`.
