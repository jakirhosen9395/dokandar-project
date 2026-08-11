// Package dkdplatform — shared spine mechanics (PL-02): transactional outbox,
// consumer inbox, and DLQ/park adapters. Canon: EF §21.1 / EF-EVT-6 /
// SA-CONV-QUARTET (outbox+inbox = effectively-once), SA-MSG-09/10 (DLQ +
// per-key park-and-freeze). These helpers are DRIVER-AGNOSTIC: they run against
// the minimal DB interface below, so a service supplies the concrete tx handle
// (pgx / database/sql) at propagation time and the helpers stay unit-testable
// without a live database.
package dkdplatform

import "context"

// DB is the minimal execution surface every store helper depends on. A caller
// passes either a pool/connection or an in-flight transaction handle; the outbox
// Enqueue and inbox dedup MUST receive a transaction handle so the row lands
// atomically with the aggregate write (SA-CONV-QUARTET). The three method
// signatures mirror database/sql, but the return types are interfaces so any
// driver — or an in-memory fake — can satisfy them.
type DB interface {
	ExecContext(ctx context.Context, query string, args ...any) (Result, error)
	QueryRowContext(ctx context.Context, query string, args ...any) Row
	QueryContext(ctx context.Context, query string, args ...any) (Rows, error)
}

// Result is the minimal command result: the number of rows the statement
// affected. ON CONFLICT DO NOTHING reports 0 on a duplicate, which is how the
// helpers detect idempotent no-ops.
type Result interface {
	RowsAffected() (int64, error)
}

// Row is a single-row scan target (database/sql.Row / pgx.Row satisfy it).
type Row interface {
	Scan(dest ...any) error
}

// Rows is a multi-row cursor used for existence checks; the caller MUST Close.
type Rows interface {
	Next() bool
	Scan(dest ...any) error
	Close() error
	Err() error
}

// Canonical DDL for the PL-02 quartet tables. These are the SDK-standard
// schemas every context provisions in its own datastore (Finance/Custody stay
// physically isolated — R2/R1 — each keeps its OWN copy of these tables).
const (
	// SchemaOutbox — one row per emitted event, written in the aggregate's tx.
	SchemaOutbox = `
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
CREATE INDEX IF NOT EXISTS outbox_unpublished_idx ON outbox (id) WHERE published_at IS NULL;`

	// SchemaInbox — per-consumer dedup; composite PK gives fan-out consumers
	// independent progress on the same event.
	SchemaInbox = `
CREATE TABLE IF NOT EXISTS inbox (
    consumer     TEXT NOT NULL,
    event_id     TEXT NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (consumer, event_id)
);`

	// SchemaDLQ — park-and-freeze: a poison money/custody/inventory event parks
	// ONLY its own aggregate_key; other keys keep progressing (SA-MSG-10).
	SchemaDLQ = `
CREATE TABLE IF NOT EXISTS dlq (
    id            BIGSERIAL PRIMARY KEY,
    event_id      TEXT   NOT NULL,
    topic         TEXT   NOT NULL,
    key           TEXT   NOT NULL,
    payload       JSONB  NOT NULL,
    error         TEXT   NOT NULL,
    aggregate_key TEXT   NOT NULL,
    parked_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS dlq_aggregate_key_idx ON dlq (aggregate_key);`
)
