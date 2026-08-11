-- catalog-svc schema (dkd_catalog). One context, one DB (R6). Synthetic data only (ADR-024).
CREATE TABLE IF NOT EXISTS schema_migrations (
    version    INT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Product aggregate: one row per GPID; price rules ride on the aggregate row (single tx boundary).
CREATE TABLE IF NOT EXISTS products (
    gpid          TEXT PRIMARY KEY,
    category_path JSONB  NOT NULL,
    names_bn      TEXT   NOT NULL,
    names_en      TEXT,
    base_unit     TEXT   NOT NULL,
    attributes    JSONB  NOT NULL DEFAULT '{}'::jsonb,
    price_rules   JSONB  NOT NULL DEFAULT '[]'::jsonb,
    status        TEXT   NOT NULL,
    created_by    TEXT   NOT NULL,
    created_at_ms BIGINT NOT NULL,
    updated_at_ms BIGINT NOT NULL,
    version       BIGINT NOT NULL
);

-- Transactional outbox (R6): domain change + event land in ONE tx; a relay publishes to Kafka.
CREATE TABLE IF NOT EXISTS outbox (
    id             BIGSERIAL PRIMARY KEY,
    event_id       UUID   NOT NULL UNIQUE,
    topic          TEXT   NOT NULL,
    key            TEXT   NOT NULL,
    payload        JSONB  NOT NULL,
    occurred_at_ms BIGINT NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at   TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS outbox_unpublished_idx ON outbox (id) WHERE published_at IS NULL;

-- Consumer inbox dedup on event_id (effectively-once for the M5 custody projection).
CREATE TABLE IF NOT EXISTS inbox (
    event_id     TEXT PRIMARY KEY,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- M5 intra-context projection: active custody passports per GPID (blocks DeprecateProduct).
CREATE TABLE IF NOT EXISTS active_passport_counts (
    gpid  TEXT PRIMARY KEY,
    count BIGINT NOT NULL DEFAULT 0
);

-- Idempotency-Key dedup for unsafe REST writes.
CREATE TABLE IF NOT EXISTS cmd_idempotency (
    idem_key     TEXT PRIMARY KEY,
    request_hash TEXT  NOT NULL,
    status_code  INT   NOT NULL,
    response     JSONB NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
