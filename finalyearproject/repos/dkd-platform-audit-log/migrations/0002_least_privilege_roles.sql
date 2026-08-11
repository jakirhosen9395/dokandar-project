-- AUD-01: least-privilege DB roles for the WORM audit sink.
--   audit_log_writer — INSERT-only (the WORM reject-trigger already blocks UPDATE/DELETE/TRUNCATE
--                      for EVERY role, so the writer is structurally append-only).
--   audit_log_reader — SELECT-only, for the Government OHS read-only consumer (R5).
-- Idempotent; tolerant of a non-superuser migrator (skips with a NOTICE if it lacks CREATEROLE, so
-- the sink still boots — a DBA can then apply the roles out-of-band).
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'audit_log_writer') THEN CREATE ROLE audit_log_writer NOLOGIN; END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'audit_log_reader') THEN CREATE ROLE audit_log_reader NOLOGIN; END IF;
    REVOKE ALL ON audit_log FROM audit_log_writer, audit_log_reader;
    GRANT INSERT ON audit_log TO audit_log_writer;   -- append-only writer
    GRANT SELECT ON audit_log TO audit_log_reader;   -- read-only Government reader (R5)
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'AUD-01: skipping least-privilege role creation (migrator lacks CREATEROLE) — apply via DBA';
END $$;
