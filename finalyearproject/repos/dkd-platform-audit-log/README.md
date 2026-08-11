# audit-log-svc

**DOKANDAR Context #13 (Platform)** — the append-only **OHS audit sink** (R6). It subscribes to the
entire Kafka spine and durably records every event, effectively once, into a write-once (WORM) store.
It is a pure consumer: it **never produces events** and **never creates topics**.

Trace: R6, ADR-024, W1, DOKANDAR-Service-Architecture.md #13 (row 32).

## What it does
- Consumes **all** spine topics (`dkdplatform.AllTopics()`) via a single stable consumer group using
  **franz-go** — the platform's first real Kafka client and the reference for future consumers.
- Appends each event to `dkd_platform.audit_log`, an **append-only WORM** table (UPDATE/DELETE rejected
  by a trigger + REVOKE). **Inbox dedup on `event_id`** gives effectively-once persistence.
- **PII producer-contract guard (CORRECTION 1):** if a spine payload carries a PII-shaped field it is
  ALWAYS still appended; a quarantine copy is written and a metric raised. It never drops or rejects.
- **No auto-create (CORRECTION 2):** subscribing to a not-yet-existing topic does not create it.
- Poison messages are parked in a DLQ (park-and-freeze), never silently dropped.

## Endpoints
- `/health`, `/live`, `/ready` (green only once Kafka + DB are connected), `/version`
- `/docs` (Swagger UI) + `/swagger/v1/swagger.json` (OpenAPI 3.0.3, Bearer)
- `/metrics` (Prometheus text) on the metrics port

## Configuration
See `.env.example`. Key vars: `DKD_KAFKA_BROKERS`, `DKD_DB_DSN` (or the discrete `DKD_DB_*`),
`DKD_CONSUMER_GROUP`, and `DKD_EXTRA_TOPICS` (isolated verification/backfill topics appended to the
canonical set — never a business coupling).

## Build / test
`make vet build test` (unit) · `make itest` (integration; needs `DKD_TEST_DB_DSN` +
`DKD_TEST_KAFKA_BROKERS`) · `make cover`. The dkd-platform SDK is **vendored byte-identically at
v1.3.0** (`sdk/dkdplatform`, via a `replace` directive), since dkd-platform-libs publishes only plain
`vX.Y.Z` tags (no `sdk/go`-subdir module tags).
