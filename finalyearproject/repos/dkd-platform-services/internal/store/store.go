// Package store — context #13's dkd_platform tables. audit-log-svc already owns audit_* in
// this database, so the two new deployables use DISJOINT tables and their own migration
// ledgers (scheduler_migrations / notification_migrations) under distinct advisory locks.
package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type OutboxRow struct {
	ID      int64
	EventID string
	Topic   string
	Key     string
	Payload []byte
}

type Store struct {
	pool   *pgxpool.Pool
	outbox string // which outbox table the relay drains (scheduler_outbox)
}

func Open(ctx context.Context, dsn string) (*Store, error) {
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return nil, fmt.Errorf("store: open pool: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("store: ping: %w", err)
	}
	return &Store{pool: pool, outbox: "scheduler_outbox"}, nil
}

func (s *Store) Close()                         { s.pool.Close() }
func (s *Store) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }

// ParkDLQ quarantines a poison consumer record after its bounded inline retries are exhausted
// (PLAT-06), so the partition advances instead of blocking forever. Idempotent on event_id.
func (s *Store) ParkDLQ(ctx context.Context, eventID, topic, key string, payload []byte, errMsg string, now int64) error {
	if len(payload) == 0 {
		payload = []byte("{}")
	}
	_, err := s.pool.Exec(ctx,
		`INSERT INTO dlq(event_id, topic, partition_key, payload, error, parked_at)
		 VALUES ($1,$2,$3,$4,$5,$6) ON CONFLICT (event_id) DO NOTHING`,
		eventID, topic, key, payload, errMsg, now)
	return err
}

// ---- migrations ----

const schedulerLock = 842014
const notificationLock = 842015

var schedulerMigrations = []string{`
CREATE TABLE IF NOT EXISTS scheduler_timers (
  esc TEXT PRIMARY KEY,
  reference_id TEXT NOT NULL DEFAULT '',
  reference_type TEXT NOT NULL DEFAULT '',
  created_at BIGINT NOT NULL,
  cooling_off_expires_at BIGINT,
  state TEXT NOT NULL CHECK (state IN ('ACTIVE','SETTLEMENT_HELD','CLOSED')),
  updated_at BIGINT NOT NULL
)`, `
CREATE INDEX IF NOT EXISTS scheduler_timers_due_idx ON scheduler_timers(state, cooling_off_expires_at)`, `
CREATE TABLE IF NOT EXISTS scheduler_fired (
  idempotency_key TEXT PRIMARY KEY,
  fired_at BIGINT NOT NULL
)`, `
CREATE TABLE IF NOT EXISTS scheduler_outbox (
  id BIGSERIAL PRIMARY KEY,
  event_id TEXT NOT NULL UNIQUE,
  topic TEXT NOT NULL,
  partition_key TEXT NOT NULL,
  payload JSONB NOT NULL,
  occurred_at BIGINT NOT NULL,
  published_at BIGINT
)`, `
CREATE INDEX IF NOT EXISTS scheduler_outbox_unpub_idx ON scheduler_outbox(id) WHERE published_at IS NULL`, `
CREATE TABLE IF NOT EXISTS scheduler_inbox (
  event_id TEXT PRIMARY KEY,
  topic TEXT NOT NULL,
  processed_at BIGINT NOT NULL
)`, `
CREATE TABLE IF NOT EXISTS dlq (
  event_id TEXT PRIMARY KEY,
  topic TEXT NOT NULL,
  partition_key TEXT NOT NULL,
  payload JSONB NOT NULL,
  error TEXT NOT NULL,
  parked_at BIGINT NOT NULL
)`}

var notificationMigrations = []string{`
CREATE TABLE IF NOT EXISTS notification_jobs (
  ntf_id TEXT PRIMARY KEY,
  recipient_did TEXT NOT NULL,
  channel TEXT NOT NULL CHECK (channel IN ('SMS','EMAIL','PUSH','USSD')),
  template_id TEXT NOT NULL,
  params JSONB NOT NULL DEFAULT '{}',
  locale TEXT NOT NULL DEFAULT 'bn-BD',
  body TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('QUEUED','SENT','FAILED','DELIVERED')),
  idempotency_key TEXT NOT NULL UNIQUE,
  created_at BIGINT NOT NULL,
  sent_at BIGINT,
  delivered_at BIGINT
)`, `
CREATE INDEX IF NOT EXISTS notification_jobs_recipient_idx ON notification_jobs(recipient_did)`, `
CREATE TABLE IF NOT EXISTS notification_inbox (
  event_id TEXT PRIMARY KEY,
  topic TEXT NOT NULL,
  processed_at BIGINT NOT NULL
)`, `
CREATE TABLE IF NOT EXISTS dlq (
  event_id TEXT PRIMARY KEY,
  topic TEXT NOT NULL,
  partition_key TEXT NOT NULL,
  payload JSONB NOT NULL,
  error TEXT NOT NULL,
  parked_at BIGINT NOT NULL
)`}

func (s *Store) MigrateScheduler(ctx context.Context, now int64) error {
	return s.migrate(ctx, schedulerLock, "scheduler_migrations", schedulerMigrations, now)
}

func (s *Store) MigrateNotification(ctx context.Context, now int64) error {
	return s.migrate(ctx, notificationLock, "notification_migrations", notificationMigrations, now)
}

func (s *Store) migrate(ctx context.Context, lock int64, ledger string, stmts []string, now int64) error {
	cx, err := s.pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("store: acquire: %w", err)
	}
	defer cx.Release()
	if _, err := cx.Exec(ctx, "SELECT pg_advisory_lock($1)", lock); err != nil {
		return fmt.Errorf("store: advisory lock: %w", err)
	}
	defer func() { _, _ = cx.Exec(ctx, "SELECT pg_advisory_unlock($1)", lock) }()
	if _, err := cx.Exec(ctx, fmt.Sprintf(
		"CREATE TABLE IF NOT EXISTS %s (version INT PRIMARY KEY, applied_at BIGINT NOT NULL)",
		ledger)); err != nil {
		return fmt.Errorf("store: create %s ledger: %w", ledger, err)
	}
	for i, stmt := range stmts {
		version := i + 1
		var exists int
		err := cx.QueryRow(ctx,
			fmt.Sprintf("SELECT 1 FROM %s WHERE version = $1", ledger), version).Scan(&exists)
		if err == nil {
			continue
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			// a transient failure must NEVER be mistaken for "not applied" (reviewer H-1)
			return fmt.Errorf("store: version check v%d: %w", version, err)
		}
		if _, err := cx.Exec(ctx, stmt); err != nil {
			return fmt.Errorf("store: migration v%d: %w", version, err)
		}
		if _, err := cx.Exec(ctx,
			fmt.Sprintf("INSERT INTO %s(version, applied_at) VALUES ($1,$2)", ledger),
			version, now); err != nil {
			return fmt.Errorf("store: record migration v%d in %s: %w", version, ledger, err)
		}
	}
	return nil
}

// ---- scheduler timers ----

type Timer struct {
	Esc                 string
	ReferenceID         string
	ReferenceType       string
	CreatedAt           int64
	CoolingOffExpiresAt *int64
	State               string
}

func (s *Store) UpsertTimerTx(ctx context.Context, tx pgx.Tx, t Timer, now int64) error {
	_, err := tx.Exec(ctx, `
	  INSERT INTO scheduler_timers(esc, reference_id, reference_type, created_at,
	    cooling_off_expires_at, state, updated_at)
	  VALUES ($1,$2,$3,$4,$5,$6,$7)
	  ON CONFLICT (esc) DO UPDATE SET
	    reference_id = CASE WHEN EXCLUDED.reference_id <> '' THEN EXCLUDED.reference_id
	                        ELSE scheduler_timers.reference_id END,
	    reference_type = CASE WHEN EXCLUDED.reference_type <> '' THEN EXCLUDED.reference_type
	                          ELSE scheduler_timers.reference_type END,
	    cooling_off_expires_at = COALESCE(EXCLUDED.cooling_off_expires_at,
	                                      scheduler_timers.cooling_off_expires_at),
	    -- forward-only (reviewer M-2): a late replay never reopens a CLOSED timer
	    state = CASE WHEN scheduler_timers.updated_at <= EXCLUDED.updated_at
	                 THEN EXCLUDED.state ELSE scheduler_timers.state END,
	    updated_at = GREATEST(scheduler_timers.updated_at, EXCLUDED.updated_at)`,
		t.Esc, t.ReferenceID, t.ReferenceType, t.CreatedAt, t.CoolingOffExpiresAt, t.State, now)
	return err
}

func (s *Store) CloseTimerTx(ctx context.Context, tx pgx.Tx, esc string, now int64) error {
	_, err := tx.Exec(ctx,
		`UPDATE scheduler_timers SET state = 'CLOSED', updated_at = $2 WHERE esc = $1`, esc, now)
	return err
}

func (s *Store) DueCoolingOff(ctx context.Context, now int64, limit int) ([]Timer, error) {
	return s.timers(ctx, `SELECT esc, reference_id, reference_type, created_at,
	  cooling_off_expires_at, state FROM scheduler_timers
	  WHERE state = 'SETTLEMENT_HELD' AND cooling_off_expires_at IS NOT NULL
	    AND cooling_off_expires_at <= $1 LIMIT $2`, now, limit)
}

func (s *Store) DueAbandoned(ctx context.Context, cutoff int64, limit int) ([]Timer, error) {
	return s.timers(ctx, `SELECT esc, reference_id, reference_type, created_at,
	  cooling_off_expires_at, state FROM scheduler_timers
	  WHERE state = 'ACTIVE' AND created_at <= $1 LIMIT $2`, cutoff, limit)
}

func (s *Store) timers(ctx context.Context, sql string, arg int64, limit int) ([]Timer, error) {
	rows, err := s.pool.Query(ctx, sql, arg, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Timer
	for rows.Next() {
		var t Timer
		if err := rows.Scan(&t.Esc, &t.ReferenceID, &t.ReferenceType, &t.CreatedAt,
			&t.CoolingOffExpiresAt, &t.State); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// FireOnce inserts the outbox event and the fired-key atomically; returns false on replays.
func (s *Store) FireOnce(ctx context.Context, firedKey string, ev OutboxRow, now int64) (bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	tag, err := tx.Exec(ctx, `INSERT INTO scheduler_fired(idempotency_key, fired_at)
	  VALUES ($1,$2) ON CONFLICT DO NOTHING`, firedKey, now)
	if err != nil {
		return false, err
	}
	if tag.RowsAffected() == 0 {
		return false, tx.Commit(ctx)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO scheduler_outbox(event_id, topic, partition_key,
	  payload, occurred_at) VALUES ($1,$2,$3,$4,$5)`,
		ev.EventID, ev.Topic, ev.Key, ev.Payload, now); err != nil {
		return false, err
	}
	return true, tx.Commit(ctx)
}

// ---- consumer inbox (per-deployable tables) ----

func (s *Store) ConsumeOnceIn(ctx context.Context, inboxTable, eventID, topic string, now int64,
	fn func(pgx.Tx) error) (bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	tag, err := tx.Exec(ctx, fmt.Sprintf(`INSERT INTO %s(event_id, topic, processed_at)
	  VALUES ($1,$2,$3) ON CONFLICT DO NOTHING`, inboxTable), eventID, topic, now)
	if err != nil {
		return false, err
	}
	if tag.RowsAffected() == 0 {
		return false, tx.Commit(ctx)
	}
	if err := fn(tx); err != nil {
		return false, err
	}
	return true, tx.Commit(ctx)
}

// ---- relay contract (scheduler_outbox) ----

func (s *Store) FetchUnpublished(ctx context.Context, limit int) ([]OutboxRow, error) {
	rows, err := s.pool.Query(ctx, `SELECT id, event_id, topic, partition_key, payload
	  FROM scheduler_outbox WHERE published_at IS NULL ORDER BY id LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []OutboxRow
	for rows.Next() {
		var r OutboxRow
		if err := rows.Scan(&r.ID, &r.EventID, &r.Topic, &r.Key, &r.Payload); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *Store) MarkPublished(ctx context.Context, ids []int64) error {
	if len(ids) == 0 {
		return nil
	}
	_, err := s.pool.Exec(ctx, `UPDATE scheduler_outbox
	  SET published_at = (EXTRACT(EPOCH FROM now())*1000)::BIGINT WHERE id = ANY($1)`, ids)
	return err
}

// ---- notification jobs ----

type Job struct {
	NtfID        string          `json:"ntfId"`
	RecipientDid string          `json:"recipientDid"`
	Channel      string          `json:"channel"`
	TemplateID   string          `json:"templateId"`
	Params       json.RawMessage `json:"params"`
	Locale       string          `json:"locale"`
	Body         string          `json:"body"`
	Status       string          `json:"status"`
	CreatedAt    int64           `json:"createdAt"`
	SentAt       *int64          `json:"sentAt,omitempty"`
	DeliveredAt  *int64          `json:"deliveredAt,omitempty"`
}

// InsertJobTx enqueues one NotificationJob; idempotent on idempotency_key (SA invariant).
func (s *Store) InsertJobTx(ctx context.Context, tx pgx.Tx, j Job, idemKey string) (bool, error) {
	tag, err := tx.Exec(ctx, `INSERT INTO notification_jobs(ntf_id, recipient_did, channel,
	  template_id, params, locale, body, status, idempotency_key, created_at)
	  VALUES ($1,$2,$3,$4,$5,$6,$7,'QUEUED',$8,$9) ON CONFLICT (idempotency_key) DO NOTHING`,
		j.NtfID, j.RecipientDid, j.Channel, j.TemplateID, j.Params, j.Locale, j.Body,
		idemKey, j.CreatedAt)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

func (s *Store) InsertJob(ctx context.Context, j Job, idemKey string) (bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	fresh, err := s.InsertJobTx(ctx, tx, j, idemKey)
	if err != nil {
		return false, err
	}
	return fresh, tx.Commit(ctx)
}

// MarkFailed parks a job that exhausted its delivery retries (never silently dropped).
func (s *Store) MarkFailed(ctx context.Context, ntfID string, now int64) error {
	_, err := s.pool.Exec(ctx, `UPDATE notification_jobs SET status = 'FAILED'
	  WHERE ntf_id = $1 AND status = 'QUEUED'`, ntfID)
	return err
}

// MarkSent flips QUEUED -> SENT (dev-sink delivery adapter); CAS on status.
func (s *Store) MarkSent(ctx context.Context, ntfID string, now int64) (bool, error) {
	tag, err := s.pool.Exec(ctx, `UPDATE notification_jobs SET status = 'SENT', sent_at = $2
	  WHERE ntf_id = $1 AND status = 'QUEUED'`, ntfID, now)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

func (s *Store) GetJob(ctx context.Context, ntfID string) (Job, bool, error) {
	var j Job
	err := s.pool.QueryRow(ctx, `SELECT ntf_id, recipient_did, channel, template_id,
	  params, locale, body, status, created_at, sent_at, delivered_at
	  FROM notification_jobs WHERE ntf_id = $1`, ntfID).Scan(
		&j.NtfID, &j.RecipientDid, &j.Channel, &j.TemplateID, &j.Params, &j.Locale, &j.Body,
		&j.Status, &j.CreatedAt, &j.SentAt, &j.DeliveredAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Job{}, false, nil
	}
	if err != nil {
		return Job{}, false, err
	}
	return j, true, nil
}

func (s *Store) JobsByRecipient(ctx context.Context, did string, limit int) ([]Job, error) {
	rows, err := s.pool.Query(ctx, `SELECT ntf_id, recipient_did, channel, template_id,
	  params, locale, body, status, created_at, sent_at, delivered_at
	  FROM notification_jobs WHERE recipient_did = $1 ORDER BY created_at DESC LIMIT $2`,
		did, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Job
	for rows.Next() {
		var j Job
		if err := rows.Scan(&j.NtfID, &j.RecipientDid, &j.Channel, &j.TemplateID, &j.Params,
			&j.Locale, &j.Body, &j.Status, &j.CreatedAt, &j.SentAt, &j.DeliveredAt); err != nil {
			return nil, err
		}
		out = append(out, j)
	}
	return out, rows.Err()
}
