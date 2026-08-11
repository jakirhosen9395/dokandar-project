-- custody-ledger-svc schema (dkd_custody, DEDICATED instance — R1/R2-grade isolation).
-- Append-only WORM at three layers: DB privileges + reject triggers, app invariants, hash chain.
CREATE TABLE IF NOT EXISTS schema_migrations (
    version    INT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The ledger: one row per event per PPID chain membership. INSERT-only.
CREATE TABLE IF NOT EXISTS passport_event (
    ppid         TEXT   NOT NULL,
    sequence_no  BIGINT NOT NULL,
    event_type   TEXT   NOT NULL,
    event_id     TEXT   NOT NULL,
    payload      JSONB  NOT NULL,
    prev_hash    TEXT   NOT NULL, -- row-level linkage ('' for genesis/anchors)
    event_hash   TEXT   NOT NULL,
    occurred_at_ms BIGINT NOT NULL,
    PRIMARY KEY (ppid, sequence_no)
);
CREATE INDEX IF NOT EXISTS passport_event_event_id_idx ON passport_event (event_id);

CREATE OR REPLACE FUNCTION passport_event_worm() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'passport_event is append-only (WORM): % is not permitted', TG_OP;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS passport_event_no_update ON passport_event;
CREATE TRIGGER passport_event_no_update BEFORE UPDATE ON passport_event
    FOR EACH ROW EXECUTE FUNCTION passport_event_worm();
DROP TRIGGER IF EXISTS passport_event_no_delete ON passport_event;
CREATE TRIGGER passport_event_no_delete BEFORE DELETE ON passport_event
    FOR EACH ROW EXECUTE FUNCTION passport_event_worm();
REVOKE UPDATE, DELETE, TRUNCATE ON passport_event FROM PUBLIC;

-- Minimal local read model (rebuildable fold of the chain).
CREATE TABLE IF NOT EXISTS passport_head (
    ppid           TEXT PRIMARY KEY,
    gpid           TEXT   NOT NULL,
    state          TEXT   NOT NULL,
    current_holder TEXT   NOT NULL,
    holder_role    TEXT   NOT NULL,
    quantity       BIGINT NOT NULL,
    unit           TEXT   NOT NULL,
    last_sequence  BIGINT NOT NULL,
    head_hash      TEXT   NOT NULL
);
CREATE INDEX IF NOT EXISTS passport_head_gpid_idx ON passport_head (gpid, state);

-- Transactional outbox (R6): chain rows + head + outbox in ONE tx; relay publishes.
CREATE TABLE IF NOT EXISTS outbox (
    id             BIGSERIAL PRIMARY KEY,
    event_id       TEXT   NOT NULL UNIQUE,
    topic          TEXT   NOT NULL,
    key            TEXT   NOT NULL,
    payload        JSONB  NOT NULL,
    occurred_at_ms BIGINT NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at   TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS outbox_unpublished_idx ON outbox (id) WHERE published_at IS NULL;

-- Inbox dedup for consumed directives (government.oversight.RecallDirectiveIssued.v1).
CREATE TABLE IF NOT EXISTS inbox (
    event_id     TEXT PRIMARY KEY,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Idempotency-Key dedup for unsafe REST writes.
CREATE TABLE IF NOT EXISTS cmd_idempotency (
    idem_key     TEXT PRIMARY KEY,
    request_hash TEXT  NOT NULL,
    status_code  INT   NOT NULL,
    response     JSONB NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
