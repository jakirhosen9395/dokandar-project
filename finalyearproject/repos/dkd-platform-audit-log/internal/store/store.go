// Package store is the append-only WORM persistence adapter (pgx/Postgres) for the audit sink.
package store

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"sort"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"gitlab.com/final-year-project3354127/audit-log-svc/internal/audit"
	"gitlab.com/final-year-project3354127/audit-log-svc/migrations"
)

// Postgres is the sink's store of record. audit_log is INSERT-only (WORM), enforced by a reject
// trigger plus revoked UPDATE/DELETE. Inbox dedup on event_id gives effectively-once persistence
// under Kafka's at-least-once delivery.
type Postgres struct {
	pool *pgxpool.Pool
}

// Open connects the pool (simple protocol so multi-statement migrations and arg queries both work)
// and verifies connectivity.
func Open(ctx context.Context, dsn string) (*Postgres, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse dsn: %w", err)
	}
	cfg.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("pgxpool: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("db ping: %w", err)
	}
	return &Postgres{pool: pool}, nil
}

func (s *Postgres) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }
func (s *Postgres) Close()                         { s.pool.Close() }

// Migrate applies the embedded, ordered SQL migrations idempotently (tracked in schema_migrations).
func (s *Postgres) Migrate(ctx context.Context) error {
	if _, err := s.pool.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version text PRIMARY KEY, applied_at_ms bigint NOT NULL DEFAULT (extract(epoch from now())*1000)::bigint)`); err != nil {
		return fmt.Errorf("ensure schema_migrations: %w", err)
	}
	names, err := migrationNames()
	if err != nil {
		return err
	}
	for _, name := range names {
		var exists bool
		if err := s.pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version=$1)`, name).Scan(&exists); err != nil {
			return fmt.Errorf("check migration %s: %w", name, err)
		}
		if exists {
			continue
		}
		body, err := migrations.FS.ReadFile(name)
		if err != nil {
			return fmt.Errorf("read migration %s: %w", name, err)
		}
		if _, err := s.pool.Exec(ctx, string(body)); err != nil {
			return fmt.Errorf("apply migration %s: %w", name, err)
		}
		if _, err := s.pool.Exec(ctx, `INSERT INTO schema_migrations(version) VALUES($1) ON CONFLICT (version) DO NOTHING`, name); err != nil {
			return fmt.Errorf("record migration %s: %w", name, err)
		}
	}
	return nil
}

func migrationNames() ([]string, error) {
	var names []string
	err := fs.WalkDir(migrations.FS, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() && len(p) > 4 && p[len(p)-4:] == ".sql" {
			names = append(names, p)
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("scan migrations: %w", err)
	}
	sort.Strings(names)
	return names, nil
}

// nonNilStrings coerces a nil slice to an empty (non-nil) slice so a NOT NULL text[] column receives
// '{}' rather than NULL.
func nonNilStrings(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

// Append writes one audit record. ON CONFLICT (event_id) DO NOTHING implements inbox dedup:
// a duplicate event_id returns inserted=false (row count unchanged), never an error.
func (s *Postgres) Append(ctx context.Context, rec audit.Record) (bool, error) {
	var id int64
	err := s.pool.QueryRow(ctx, `
		INSERT INTO audit_log
			(event_id, topic, event_key, kafka_partition, kafka_offset, payload, ingested_at_ms, pii_flagged, pii_fields)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
		ON CONFLICT (event_id) DO NOTHING
		RETURNING id`,
		rec.EventID, rec.Topic, rec.Key, rec.Partition, rec.Offset, rec.Payload, rec.IngestedAtMs, rec.PIIFlagged, nonNilStrings(rec.PIIFields),
	).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("append: %w", err)
	}
	return true, nil
}

// QuarantinePII stores an additional copy of a PII-flagged record (CORRECTION 1). The original is
// still appended to audit_log; this is an extra observation artifact, never a substitute.
func (s *Postgres) QuarantinePII(ctx context.Context, rec audit.Record) error {
	_, err := s.pool.Exec(ctx, `
		INSERT INTO audit_pii_quarantine (event_id, topic, event_key, pii_fields, payload, quarantined_at_ms)
		VALUES ($1,$2,$3,$4,$5,$6)
		ON CONFLICT (event_id) DO NOTHING`,
		rec.EventID, rec.Topic, rec.Key, nonNilStrings(rec.PIIFields), rec.Payload, rec.IngestedAtMs)
	if err != nil {
		return fmt.Errorf("quarantine: %w", err)
	}
	return nil
}

// ParkDLQ writes a poison record to the dead-letter table (park-and-freeze; never dropped).
func (s *Postgres) ParkDLQ(ctx context.Context, e audit.RawEvent, reason string, nowMs int64) error {
	_, err := s.pool.Exec(ctx, `
		INSERT INTO audit_dlq (event_id, topic, event_key, kafka_partition, kafka_offset, payload, reason, parked_at_ms)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`,
		e.EventID, e.Topic, e.Key, e.Partition, e.Offset, e.Value, reason, nowMs)
	if err != nil {
		return fmt.Errorf("park dlq: %w", err)
	}
	return nil
}

// Exec is a low-level passthrough used by integration tests (e.g. to assert WORM rejects UPDATE).
func (s *Postgres) Exec(ctx context.Context, sql string, args ...any) error {
	_, err := s.pool.Exec(ctx, sql, args...)
	return err
}

// QueryRowInt runs a scalar-int query (test/evidence helper).
func (s *Postgres) QueryRowInt(ctx context.Context, sql string, args ...any) (int, error) {
	var n int
	err := s.pool.QueryRow(ctx, sql, args...).Scan(&n)
	return n, err
}
