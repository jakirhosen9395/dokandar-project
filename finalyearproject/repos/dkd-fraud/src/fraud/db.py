"""Postgres pool + code-first migrations under pg_advisory_lock(842010) — fleet pattern
(custody 842003, inventory 842005, b2c 842006, b2b 842007, finance 842008, logistics 842009)."""

from __future__ import annotations

import logging

from psycopg_pool import ConnectionPool

log = logging.getLogger("fraud.db")

ADVISORY_LOCK_KEY = 842010

MIGRATIONS: list[tuple[int, str, list[str]]] = [
    (
        1,
        "fraud core: signals (append-only), pending_holds (four-eyes), outbox/inbox/idempotency",
        [
            """
            CREATE TABLE IF NOT EXISTS fraud_signals (
              signal_id TEXT PRIMARY KEY,
              subject_did TEXT NOT NULL,
              reason TEXT NOT NULL,
              risk_score DOUBLE PRECISION NOT NULL,
              evidence JSONB,
              raised_by TEXT NOT NULL,
              raised_at BIGINT NOT NULL
            )""",
            "CREATE INDEX IF NOT EXISTS fraud_signals_subject_idx ON fraud_signals(subject_did)",
            """
            CREATE OR REPLACE FUNCTION fraud_signals_worm() RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION 'fraud_signals is append-only: % blocked', TG_OP;
            END $$ LANGUAGE plpgsql""",
            "DROP TRIGGER IF EXISTS fraud_signals_guard ON fraud_signals",
            """
            CREATE TRIGGER fraud_signals_guard BEFORE UPDATE OR DELETE ON fraud_signals
            FOR EACH ROW EXECUTE FUNCTION fraud_signals_worm()""",
            """
            CREATE TABLE IF NOT EXISTS pending_holds (
              subject_did TEXT PRIMARY KEY,
              reason TEXT NOT NULL,
              approver1 TEXT NOT NULL,
              evidence JSONB,
              status TEXT NOT NULL CHECK (status IN ('PENDING','APPROVED','RELEASED')),
              approver2 TEXT,
              requested_at BIGINT NOT NULL,
              approved_at BIGINT,
              released_at BIGINT
            )""",
            """
            CREATE TABLE IF NOT EXISTS outbox (
              id BIGSERIAL PRIMARY KEY,
              event_id TEXT NOT NULL UNIQUE,
              topic TEXT NOT NULL,
              partition_key TEXT NOT NULL,
              payload JSONB NOT NULL,
              occurred_at BIGINT NOT NULL,
              published_at BIGINT
            )""",
            "CREATE INDEX IF NOT EXISTS outbox_unpublished_idx ON outbox(id) "
            "WHERE published_at IS NULL",
            """
            CREATE TABLE IF NOT EXISTS inbox (
              event_id TEXT PRIMARY KEY,
              topic TEXT NOT NULL,
              processed_at BIGINT NOT NULL
            )""",
            """
            CREATE TABLE IF NOT EXISTS cmd_idempotency (
              idem_key TEXT NOT NULL,
              endpoint TEXT NOT NULL,
              request_hash TEXT NOT NULL,
              response_status INT NOT NULL,
              response_body JSONB NOT NULL,
              created_at BIGINT NOT NULL,
              PRIMARY KEY (idem_key, endpoint)
            )""",
        ],
    ),
    (
        2,
        "FRAUD-06: DLQ sink for bounded-retry poison quarantine",
        [
            """
            CREATE TABLE IF NOT EXISTS dlq (
              id BIGSERIAL PRIMARY KEY,
              event_id TEXT NOT NULL,
              topic TEXT NOT NULL,
              key TEXT NOT NULL DEFAULT '',
              payload JSONB NOT NULL,
              error TEXT NOT NULL,
              parked_at BIGINT NOT NULL
            )""",
            "CREATE INDEX IF NOT EXISTS dlq_event_idx ON dlq(event_id)",
        ],
    ),
]


def open_pool(dsn: str) -> ConnectionPool:
    pool: ConnectionPool = ConnectionPool(dsn, min_size=1, max_size=8, open=True)
    pool.wait(timeout=30)
    return pool


def migrate(pool: ConnectionPool, now_ms: int) -> None:
    with pool.connection() as cx:
        cx.execute("SET lock_timeout = '30s'")  # never wedge the pool on a stuck migrator
        cx.execute("SELECT pg_advisory_lock(%s)", (ADVISORY_LOCK_KEY,))
        try:
            cx.execute(
                "CREATE TABLE IF NOT EXISTS schema_migrations ("
                "version INT PRIMARY KEY, description TEXT NOT NULL, applied_at BIGINT NOT NULL)"
            )
            cx.commit()
            for version, description, statements in MIGRATIONS:
                cur = cx.execute("SELECT 1 FROM schema_migrations WHERE version = %s", (version,))
                if cur.fetchone() is not None:
                    continue
                for sql in statements:
                    cx.execute(sql)
                cx.execute(
                    "INSERT INTO schema_migrations(version, description, applied_at) "
                    "VALUES (%s,%s,%s)",
                    (version, description, now_ms),
                )
                cx.commit()
                log.info("migration v%d applied: %s", version, description)
        finally:
            cx.execute("SELECT pg_advisory_unlock(%s)", (ADVISORY_LOCK_KEY,))
            cx.commit()
