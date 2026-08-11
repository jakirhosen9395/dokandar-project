-- inventory-svc schema (dkd_inventory). READ-SIDE projection of custody (R1) + G2 reservations.
CREATE TABLE IF NOT EXISTS schema_migrations (
    version    INT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One row per custody lot (PPID) — the strong-LOCAL stock record. Holder DID doubles as the
-- location key (custody payloads carry no separate location — BUILD LOG decision).
CREATE TABLE IF NOT EXISTS stock_record (
    ppid          TEXT PRIMARY KEY,
    gpid          TEXT   NOT NULL,
    holder        TEXT   NOT NULL,
    quantity      BIGINT NOT NULL,
    unit          TEXT   NOT NULL,
    state         TEXT   NOT NULL, -- ON_HAND | QUARANTINED | RETIRED (split/merged away)
    updated_at_ms BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS stock_record_gh_idx ON stock_record (gpid, holder, state);
CREATE INDEX IF NOT EXISTS stock_record_gpid_idx ON stock_record (gpid, state);

-- Append-only movement trace: every delta cites the causing custody event_id.
CREATE TABLE IF NOT EXISTS stock_movement (
    id            BIGSERIAL PRIMARY KEY,
    ppid          TEXT   NOT NULL,
    gpid          TEXT   NOT NULL,
    event_id      TEXT   NOT NULL,
    event_type    TEXT   NOT NULL,
    detail        TEXT   NOT NULL,
    occurred_at_ms BIGINT NOT NULL
);

-- G2 reservations: HELD stock owned SOLELY by inventory-svc; CAS against strong-local records.
CREATE TABLE IF NOT EXISTS reservation (
    res_id        TEXT PRIMARY KEY,
    gpid          TEXT   NOT NULL,
    holder        TEXT   NOT NULL,
    quantity      BIGINT NOT NULL,
    state         TEXT   NOT NULL, -- HELD | RELEASED | CONSUMED
    idem_key      TEXT   NOT NULL UNIQUE,
    created_at_ms BIGINT NOT NULL,
    updated_at_ms BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS reservation_gh_idx ON reservation (gpid, holder, state);

-- Inbox dedup on upstream event_id (effectively-once projection).
CREATE TABLE IF NOT EXISTS inbox (
    event_id     TEXT PRIMARY KEY,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
