// Package store persists the Product aggregate in dkd_catalog (one context, one DB — R6)
// with a transactional outbox: every domain change and its events commit in ONE tx.
package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"sort"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"

	"gitlab.com/final-year-project3354127/catalog-svc/internal/catalog"
	"gitlab.com/final-year-project3354127/catalog-svc/migrations"
)

var (
	ErrNotFound        = errors.New("store: not found")
	ErrVersionConflict = errors.New("store: version conflict")
	// ErrActivePassports guards the M5 invariant inside the deprecation transaction.
	ErrActivePassports = errors.New("store: active custody passports reference this gpid")
)

type Store struct {
	pool *pgxpool.Pool
}

func Open(ctx context.Context, dsn string) (*Store, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("store: parse dsn: %w", err)
	}
	cfg.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("store: connect: %w", err)
	}
	return &Store{pool: pool}, nil
}

func (s *Store) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }
func (s *Store) Close()                         { s.pool.Close() }

// Migrate applies each embedded migration exactly once: already-recorded versions are
// SKIPPED entirely (their SQL is never re-executed), so future non-idempotent statements
// (e.g. ALTER TABLE ADD COLUMN) cannot fail restarts.
func (s *Store) Migrate(ctx context.Context) error {
	if _, err := s.pool.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version INT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())`); err != nil {
		return fmt.Errorf("store: ensure schema_migrations: %w", err)
	}
	entries, err := fs.ReadDir(migrations.FS, ".")
	if err != nil {
		return fmt.Errorf("store: read migrations: %w", err)
	}
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	for i, name := range names {
		var applied bool
		if err := s.pool.QueryRow(ctx,
			"SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version=$1)", i+1).Scan(&applied); err != nil {
			return fmt.Errorf("store: check %s: %w", name, err)
		}
		if applied {
			continue
		}
		sql, err := fs.ReadFile(migrations.FS, name)
		if err != nil {
			return fmt.Errorf("store: read %s: %w", name, err)
		}
		tx, err := s.pool.Begin(ctx)
		if err != nil {
			return fmt.Errorf("store: begin: %w", err)
		}
		if _, err := tx.Exec(ctx, string(sql)); err != nil {
			_ = tx.Rollback(ctx)
			return fmt.Errorf("store: apply %s: %w", name, err)
		}
		if _, err := tx.Exec(ctx,
			"INSERT INTO schema_migrations (version) VALUES ($1) ON CONFLICT (version) DO NOTHING", i+1); err != nil {
			_ = tx.Rollback(ctx)
			return fmt.Errorf("store: record %s: %w", name, err)
		}
		if err := tx.Commit(ctx); err != nil {
			return fmt.Errorf("store: commit %s: %w", name, err)
		}
	}
	return nil
}

func insertOutbox(ctx context.Context, tx pgx.Tx, evs []catalog.Event) error {
	for _, ev := range evs {
		if _, err := tx.Exec(ctx,
			`INSERT INTO outbox (event_id, topic, key, payload, occurred_at_ms) VALUES ($1,$2,$3,$4,$5)`,
			ev.EventID, ev.Topic, ev.Key, string(ev.Payload), ev.OccurredAtMs); err != nil {
			return fmt.Errorf("store: outbox insert: %w", err)
		}
	}
	return nil
}

func productArgs(p *catalog.Product) ([]any, error) {
	path, err := json.Marshal(p.CategoryPath)
	if err != nil {
		return nil, err
	}
	attrs, err := json.Marshal(p.Attributes)
	if err != nil {
		return nil, err
	}
	rules, err := json.Marshal(p.PriceRules)
	if err != nil {
		return nil, err
	}
	return []any{string(p.GPID), string(path), p.NamesBn, p.NamesEn, p.BaseUnit,
		string(attrs), string(rules), string(p.Status), p.CreatedBy,
		p.CreatedAtMs, p.UpdatedAtMs, p.Version}, nil
}

// SaveNewProduct inserts the aggregate and its events in ONE transaction (R6 outbox invariant).
func (s *Store) SaveNewProduct(ctx context.Context, p *catalog.Product, evs []catalog.Event) error {
	args, err := productArgs(p)
	if err != nil {
		return fmt.Errorf("store: marshal product: %w", err)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `INSERT INTO products
		(gpid, category_path, names_bn, names_en, base_unit, attributes, price_rules, status,
		 created_by, created_at_ms, updated_at_ms, version)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`, args...); err != nil {
		return fmt.Errorf("store: insert product: %w", err)
	}
	if err := insertOutbox(ctx, tx, evs); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func execProductUpdate(ctx context.Context, tx pgx.Tx, p *catalog.Product, prevVersion int64, evs []catalog.Event) error {
	args, err := productArgs(p)
	if err != nil {
		return fmt.Errorf("store: marshal product: %w", err)
	}
	tag, err := tx.Exec(ctx, `UPDATE products SET
		category_path=$2, names_bn=$3, names_en=$4, base_unit=$5, attributes=$6, price_rules=$7,
		status=$8, created_by=$9, created_at_ms=$10, updated_at_ms=$11, version=$12
		WHERE gpid=$1 AND version=$13`, append(args, prevVersion)...)
	if err != nil {
		return fmt.Errorf("store: update product: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrVersionConflict
	}
	return insertOutbox(ctx, tx, evs)
}

// UpdateProduct persists a mutated aggregate guarded by optimistic versioning, plus its events.
func (s *Store) UpdateProduct(ctx context.Context, p *catalog.Product, prevVersion int64, evs []catalog.Event) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if err := execProductUpdate(ctx, tx, p, prevVersion, evs); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// UpdateProductDeprecating closes the M5 TOCTOU: inside ONE transaction it takes a row lock on
// the passport count (upsert-with-lock so an absent row is also locked), re-checks it is zero,
// and only then applies the product update + events. A concurrent ApplyPassportDelta blocks on
// the lock until this commits.
func (s *Store) UpdateProductDeprecating(ctx context.Context, p *catalog.Product, prevVersion int64, evs []catalog.Event) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	var n int64
	if err := tx.QueryRow(ctx, `INSERT INTO active_passport_counts (gpid, count) VALUES ($1, 0)
		ON CONFLICT (gpid) DO UPDATE SET count = active_passport_counts.count
		RETURNING count`, string(p.GPID)).Scan(&n); err != nil {
		return fmt.Errorf("store: lock passport count: %w", err)
	}
	if n > 0 {
		return ErrActivePassports
	}
	if err := execProductUpdate(ctx, tx, p, prevVersion, evs); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func scanProduct(row pgx.Row) (*catalog.Product, error) {
	var p catalog.Product
	var path, attrs, rules []byte
	var namesEn *string
	var status, gpid string
	if err := row.Scan(&gpid, &path, &p.NamesBn, &namesEn, &p.BaseUnit, &attrs, &rules,
		&status, &p.CreatedBy, &p.CreatedAtMs, &p.UpdatedAtMs, &p.Version); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("store: scan product: %w", err)
	}
	p.GPID = dkd.GPID(gpid)
	p.Status = catalog.Status(status)
	if namesEn != nil {
		p.NamesEn = *namesEn
	}
	if err := json.Unmarshal(path, &p.CategoryPath); err != nil {
		return nil, fmt.Errorf("store: category_path: %w", err)
	}
	if err := json.Unmarshal(attrs, &p.Attributes); err != nil {
		return nil, fmt.Errorf("store: attributes: %w", err)
	}
	if err := json.Unmarshal(rules, &p.PriceRules); err != nil {
		return nil, fmt.Errorf("store: price_rules: %w", err)
	}
	return &p, nil
}

const productCols = `gpid, category_path, names_bn, names_en, base_unit, attributes, price_rules,
	status, created_by, created_at_ms, updated_at_ms, version`

func (s *Store) GetProduct(ctx context.Context, gpid string) (*catalog.Product, error) {
	return scanProduct(s.pool.QueryRow(ctx,
		`SELECT `+productCols+` FROM products WHERE gpid=$1`, gpid))
}

// ListProducts pages by keyset cursor (gpid ordering) — offset pagination is banned platform-wide.
func (s *Store) ListProducts(ctx context.Context, afterGpid string, limit int) ([]*catalog.Product, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	rows, err := s.pool.Query(ctx,
		`SELECT `+productCols+` FROM products WHERE gpid > $1 ORDER BY gpid LIMIT $2`, afterGpid, limit)
	if err != nil {
		return nil, fmt.Errorf("store: list: %w", err)
	}
	defer rows.Close()
	var out []*catalog.Product
	for rows.Next() {
		p, err := scanProduct(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

type OutboxRow struct {
	ID           int64
	EventID      string
	Topic        string
	Key          string
	Payload      []byte
	OccurredAtMs int64
}

func (s *Store) FetchUnpublished(ctx context.Context, limit int) ([]OutboxRow, error) {
	rows, err := s.pool.Query(ctx, `SELECT id, event_id, topic, key, payload, occurred_at_ms
		FROM outbox WHERE published_at IS NULL ORDER BY id LIMIT $1`, limit)
	if err != nil {
		return nil, fmt.Errorf("store: fetch outbox: %w", err)
	}
	defer rows.Close()
	var out []OutboxRow
	for rows.Next() {
		var r OutboxRow
		if err := rows.Scan(&r.ID, &r.EventID, &r.Topic, &r.Key, &r.Payload, &r.OccurredAtMs); err != nil {
			return nil, fmt.Errorf("store: scan outbox: %w", err)
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *Store) MarkPublished(ctx context.Context, ids []int64) error {
	if len(ids) == 0 {
		return nil
	}
	arr, err := json.Marshal(ids)
	if err != nil {
		return fmt.Errorf("store: marshal ids: %w", err)
	}
	if _, err := s.pool.Exec(ctx,
		`UPDATE outbox SET published_at=now()
		 WHERE id IN (SELECT jsonb_array_elements_text($1::jsonb)::bigint)`, string(arr)); err != nil {
		return fmt.Errorf("store: mark published: %w", err)
	}
	return nil
}

// ApplyPassportDeltaOnce records the event_id in the inbox AND applies the count delta in ONE
// transaction (HIGH-3 review fix): a failed delta never strands a committed inbox row, so
// replays reprocess the event instead of permanently losing the count.
func (s *Store) ApplyPassportDeltaOnce(ctx context.Context, eventID, gpid string, delta int64) (bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, fmt.Errorf("store: begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	tag, err := tx.Exec(ctx,
		`INSERT INTO inbox (event_id) VALUES ($1) ON CONFLICT (event_id) DO NOTHING`, eventID)
	if err != nil {
		return false, fmt.Errorf("store: inbox: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return true, nil // duplicate — nothing to apply
	}
	if _, err := tx.Exec(ctx, `INSERT INTO active_passport_counts (gpid, count) VALUES ($1, $2)
		ON CONFLICT (gpid) DO UPDATE SET count = active_passport_counts.count + $2`, gpid, delta); err != nil {
		return false, fmt.Errorf("store: passport delta: %w", err)
	}
	return false, tx.Commit(ctx)
}

// InboxSeen records event_id and reports whether it was already processed (dedup).
func (s *Store) InboxSeen(ctx context.Context, eventID string) (bool, error) {
	tag, err := s.pool.Exec(ctx,
		`INSERT INTO inbox (event_id) VALUES ($1) ON CONFLICT (event_id) DO NOTHING`, eventID)
	if err != nil {
		return false, fmt.Errorf("store: inbox: %w", err)
	}
	return tag.RowsAffected() == 0, nil
}

// ApplyPassportDelta maintains the M5 projection.
func (s *Store) ApplyPassportDelta(ctx context.Context, gpid string, delta int64) error {
	_, err := s.pool.Exec(ctx, `INSERT INTO active_passport_counts (gpid, count) VALUES ($1, $2)
		ON CONFLICT (gpid) DO UPDATE SET count = active_passport_counts.count + $2`, gpid, delta)
	if err != nil {
		return fmt.Errorf("store: passport delta: %w", err)
	}
	return nil
}

func (s *Store) ActivePassportCount(ctx context.Context, gpid string) (int64, error) {
	var n int64
	err := s.pool.QueryRow(ctx,
		`SELECT count FROM active_passport_counts WHERE gpid=$1`, gpid).Scan(&n)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("store: passport count: %w", err)
	}
	return n, nil
}

// GetIdem returns a stored idempotent response for the key, if any.
func (s *Store) GetIdem(ctx context.Context, key string) (status int, reqHash string, resp []byte, found bool, err error) {
	err = s.pool.QueryRow(ctx,
		`SELECT status_code, request_hash, response FROM cmd_idempotency WHERE idem_key=$1`, key).
		Scan(&status, &reqHash, &resp)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, "", nil, false, nil
	}
	if err != nil {
		return 0, "", nil, false, fmt.Errorf("store: idem get: %w", err)
	}
	return status, reqHash, resp, true, nil
}

func (s *Store) PutIdem(ctx context.Context, key, reqHash string, status int, resp []byte) error {
	_, err := s.pool.Exec(ctx, `INSERT INTO cmd_idempotency (idem_key, request_hash, status_code, response)
		VALUES ($1,$2,$3,$4) ON CONFLICT (idem_key) DO NOTHING`, key, reqHash, status, string(resp))
	if err != nil {
		return fmt.Errorf("store: idem put: %w", err)
	}
	return nil
}
