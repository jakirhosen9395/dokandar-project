-- 0001_init — Context #13 Platform · audit-log-svc.
-- Append-only WORM audit_log (store of record for the R6 OHS audit sink) + inbox dedup on
-- event_id + PII quarantine copy (CORRECTION 1) + dead-letter park-and-freeze.

CREATE TABLE IF NOT EXISTS audit_log (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id        text        NOT NULL UNIQUE,          -- inbox dedup key (effectively-once)
    topic           text        NOT NULL,
    event_key       text        NOT NULL DEFAULT '',
    kafka_partition integer     NOT NULL DEFAULT 0,
    kafka_offset    bigint      NOT NULL DEFAULT 0,
    payload         bytea       NOT NULL,
    ingested_at_ms  bigint      NOT NULL,
    pii_flagged     boolean     NOT NULL DEFAULT false,
    pii_fields      text[]      NOT NULL DEFAULT '{}',
    persisted_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS audit_log_topic_idx ON audit_log (topic);
CREATE INDEX IF NOT EXISTS audit_log_pii_idx   ON audit_log (pii_flagged) WHERE pii_flagged;

-- WORM enforcement: a reject-trigger blocks UPDATE/DELETE for EVERY role (including the table
-- owner), and the privileges are additionally revoked as defense-in-depth for non-owner roles.
CREATE OR REPLACE FUNCTION audit_log_worm() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'audit_log is append-only (WORM): % is not permitted', TG_OP
        USING ERRCODE = 'insufficient_privilege';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS audit_log_no_update ON audit_log;
CREATE TRIGGER audit_log_no_update BEFORE UPDATE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION audit_log_worm();

DROP TRIGGER IF EXISTS audit_log_no_delete ON audit_log;
CREATE TRIGGER audit_log_no_delete BEFORE DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION audit_log_worm();

REVOKE UPDATE, DELETE, TRUNCATE ON audit_log FROM PUBLIC;

-- PII quarantine copy (CORRECTION 1): a flagged record is ALSO copied here while the original still
-- lands in audit_log. This is an additional observation artifact, never a substitute for the append.
CREATE TABLE IF NOT EXISTS audit_pii_quarantine (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id          text   NOT NULL UNIQUE,
    topic             text   NOT NULL,
    event_key         text   NOT NULL DEFAULT '',
    pii_fields        text[] NOT NULL DEFAULT '{}',
    payload           bytea  NOT NULL,
    quarantined_at_ms bigint NOT NULL
);

-- Dead-letter / park-and-freeze for poison messages (never silently dropped).
CREATE TABLE IF NOT EXISTS audit_dlq (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id        text    NOT NULL,
    topic           text    NOT NULL,
    event_key       text    NOT NULL DEFAULT '',
    kafka_partition integer NOT NULL DEFAULT 0,
    kafka_offset    bigint  NOT NULL DEFAULT 0,
    payload         bytea   NOT NULL,
    reason          text    NOT NULL,
    parked_at_ms    bigint  NOT NULL
);
