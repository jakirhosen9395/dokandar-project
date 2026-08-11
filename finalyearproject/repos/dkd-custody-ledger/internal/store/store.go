// Package store is the custody WORM event store on the DEDICATED dkd_custody Postgres (R1):
// chain rows + head read-model + outbox commit in ONE transaction, optimistic per-PPID
// sequencing, and full chain verification (recompute every hash + linkage).
package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/custody"
	"gitlab.com/final-year-project3354127/custody-ledger-svc/migrations"
)

var (
	ErrNotFound         = errors.New("store: not found")
	ErrSequenceConflict = errors.New("store: sequence conflict (concurrent append)")
)

type Store struct{ pool *pgxpool.Pool }

// isDuplicateKey detects SQLSTATE 23505 (unique violation) — the storage-level face of a
// lost optimistic race on chain sequence or head creation.
func isDuplicateKey(err error) bool {
	return err != nil && strings.Contains(err.Error(), "23505")
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

func (s *Store) Migrate(ctx context.Context) error {
	// Serialize concurrent migrators (M1 review fix): a session advisory lock held on a
	// dedicated connection covers the whole check-then-apply cycle.
	lockConn, err := s.pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("store: acquire migration conn: %w", err)
	}
	defer lockConn.Release()
	if _, err := lockConn.Exec(ctx, "SELECT pg_advisory_lock(842003)"); err != nil {
		return fmt.Errorf("store: migration lock: %w", err)
	}
	defer func() { _, _ = lockConn.Exec(context.Background(), "SELECT pg_advisory_unlock(842003)") }()
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

// Affected describes one PPID chain membership of a sealed event: the post-command passport
// state, whether the head row is new (genesis/split-child/merge-new), and the ROW-level
// previous hash ('' for genesis and for anchor rows of newly minted PPIDs).
type Affected struct {
	Head        *custody.Passport
	IsNew       bool
	RowPrevHash string
}

// Append commits the event atomically: one passport_event row per affected PPID, head
// insert/CAS-update, and the outbox row — all in ONE transaction (R6 outbox invariant).
// A lost CAS returns ErrSequenceConflict; callers re-read the head and retry.
func (s *Store) Append(ctx context.Context, ev custody.Event, occurredAtMs int64, affected []Affected) error {
	if len(affected) == 0 {
		return fmt.Errorf("store: append requires at least one affected passport")
	}
	payload, err := json.Marshal(ev.Fields)
	if err != nil {
		return fmt.Errorf("store: marshal payload: %w", err)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	for _, a := range affected {
		h := a.Head
		// Head first: the CAS (or insert) is the optimistic-concurrency gate; a lost race
		// surfaces as ErrSequenceConflict before any chain row is attempted.
		if a.IsNew {
			if _, err := tx.Exec(ctx, `INSERT INTO passport_head
				(ppid, gpid, state, current_holder, holder_role, quantity, unit, last_sequence, head_hash)
				VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
				h.PPID, h.GPID, string(h.Status), h.CurrentHolder, string(h.HolderRole),
				h.Quantity, h.Unit, h.Sequence, h.HeadHash); err != nil {
				if isDuplicateKey(err) {
					return ErrSequenceConflict
				}
				return fmt.Errorf("store: head insert %s: %w", h.PPID, err)
			}
		} else {
			tag, err := tx.Exec(ctx, `UPDATE passport_head SET
				state=$2, current_holder=$3, holder_role=$4, last_sequence=$5, head_hash=$6
				WHERE ppid=$1 AND last_sequence=$7`,
				h.PPID, string(h.Status), h.CurrentHolder, string(h.HolderRole),
				h.Sequence, h.HeadHash, h.Sequence-1)
			if err != nil {
				return fmt.Errorf("store: head update %s: %w", h.PPID, err)
			}
			if tag.RowsAffected() == 0 {
				return ErrSequenceConflict
			}
		}
		if _, err := tx.Exec(ctx, `INSERT INTO passport_event
			(ppid, sequence_no, event_type, event_id, payload, prev_hash, event_hash, occurred_at_ms)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`,
			h.PPID, h.Sequence, ev.Type, ev.EventID, string(payload), a.RowPrevHash, ev.EventHash, occurredAtMs); err != nil {
			if isDuplicateKey(err) {
				return ErrSequenceConflict
			}
			return fmt.Errorf("store: chain row %s: %w", h.PPID, err)
		}
	}
	if _, err := tx.Exec(ctx, `INSERT INTO outbox (event_id, topic, key, payload, occurred_at_ms)
		VALUES ($1,$2,$3,$4,$5)`, ev.EventID, ev.Type, ev.Key, string(payload), occurredAtMs); err != nil {
		return fmt.Errorf("store: outbox insert: %w", err)
	}
	return tx.Commit(ctx)
}

func (s *Store) GetHead(ctx context.Context, ppid string) (*custody.Passport, error) {
	var p custody.Passport
	var status, role string
	err := s.pool.QueryRow(ctx, `SELECT ppid, gpid, state, current_holder, holder_role,
		quantity, unit, last_sequence, head_hash FROM passport_head WHERE ppid=$1`, ppid).
		Scan(&p.PPID, &p.GPID, &status, &p.CurrentHolder, &role, &p.Quantity, &p.Unit, &p.Sequence, &p.HeadHash)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("store: head: %w", err)
	}
	p.Status, p.HolderRole = custody.Status(status), custody.Role(role)
	return &p, nil
}

// ActiveByGPID lists ACTIVE passports for a GPID (recall-directive fan-out).
// limit <= 0 means NO limit: a recall must never silently truncate its target set (C2 review fix).
func (s *Store) ActiveByGPID(ctx context.Context, gpid string, limit int) ([]*custody.Passport, error) {
	q := `SELECT ppid, gpid, state, current_holder, holder_role,
		quantity, unit, last_sequence, head_hash FROM passport_head
		WHERE gpid=$1 AND state=$2 ORDER BY ppid`
	args := []any{gpid, string(custody.StatusActive)}
	if limit > 0 {
		q += ` LIMIT $3`
		args = append(args, limit)
	}
	rows, err := s.pool.Query(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("store: by gpid: %w", err)
	}
	defer rows.Close()
	var out []*custody.Passport
	for rows.Next() {
		var p custody.Passport
		var status, role string
		if err := rows.Scan(&p.PPID, &p.GPID, &status, &p.CurrentHolder, &role,
			&p.Quantity, &p.Unit, &p.Sequence, &p.HeadHash); err != nil {
			return nil, fmt.Errorf("store: scan head: %w", err)
		}
		p.Status, p.HolderRole = custody.Status(status), custody.Role(role)
		out = append(out, &p)
	}
	return out, rows.Err()
}

type ChainRow struct {
	PPID         string
	Sequence     int64
	EventType    string
	EventID      string
	Payload      []byte
	PrevHash     string
	EventHash    string
	OccurredAtMs int64
}

func (s *Store) ListEvents(ctx context.Context, ppid string) ([]ChainRow, error) {
	rows, err := s.pool.Query(ctx, `SELECT ppid, sequence_no, event_type, event_id, payload,
		prev_hash, event_hash, occurred_at_ms FROM passport_event
		WHERE ppid=$1 ORDER BY sequence_no`, ppid)
	if err != nil {
		return nil, fmt.Errorf("store: events: %w", err)
	}
	defer rows.Close()
	var out []ChainRow
	for rows.Next() {
		var r ChainRow
		if err := rows.Scan(&r.PPID, &r.Sequence, &r.EventType, &r.EventID, &r.Payload,
			&r.PrevHash, &r.EventHash, &r.OccurredAtMs); err != nil {
			return nil, fmt.Errorf("store: scan event: %w", err)
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// VerifyChain recomputes every event hash per Spec v2 and checks row linkage + head
// consistency for one PPID. Any divergence is reported, never repaired (append-only law).
func (s *Store) VerifyChain(ctx context.Context, ppid string) (bool, string, error) {
	rows, err := s.ListEvents(ctx, ppid)
	if err != nil {
		return false, "", err
	}
	if len(rows) == 0 {
		return false, "no events for ppid", nil
	}
	var prevHash string
	for i, r := range rows {
		var fields map[string]any
		if err := json.Unmarshal(r.Payload, &fields); err != nil {
			return false, fmt.Sprintf("seq %d: payload not decodable", r.Sequence), nil
		}
		recomputed, err := custody.EventHash(fields)
		if err != nil {
			return false, fmt.Sprintf("seq %d: %v", r.Sequence, err), nil
		}
		if recomputed != r.EventHash {
			return false, fmt.Sprintf("seq %d: eventHash mismatch (tamper?)", r.Sequence), nil
		}
		if i > 0 && r.PrevHash != prevHash {
			return false, fmt.Sprintf("seq %d: chain linkage broken", r.Sequence), nil
		}
		prevHash = r.EventHash
	}
	head, err := s.GetHead(ctx, ppid)
	if err != nil {
		return false, "", err
	}
	if head.HeadHash != prevHash || head.Sequence != rows[len(rows)-1].Sequence {
		return false, "head does not match chain tip", nil
	}
	return true, "chain verified", nil
}

// InboxSeen dedupes consumed directives on event_id.
func (s *Store) InboxSeen(ctx context.Context, eventID string) (bool, error) {
	tag, err := s.pool.Exec(ctx,
		`INSERT INTO inbox (event_id) VALUES ($1) ON CONFLICT (event_id) DO NOTHING`, eventID)
	if err != nil {
		return false, fmt.Errorf("store: inbox: %w", err)
	}
	return tag.RowsAffected() == 0, nil
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

// UpsertSignerKey registers (or re-registers) a signer's PUBLIC key bound to a DID (C3-F2).
// Public keys only — private keys are never stored. Upsert makes the dev-seed path idempotent.
func (s *Store) UpsertSignerKey(ctx context.Context, keyID, publicKey, boundDID string, createdAt int64) error {
	if _, err := s.pool.Exec(ctx, `INSERT INTO signer_keys (key_id, public_key, bound_did, created_at)
		VALUES ($1,$2,$3,$4)
		ON CONFLICT (key_id) DO UPDATE SET
			public_key = EXCLUDED.public_key,
			bound_did  = EXCLUDED.bound_did,
			created_at = EXCLUDED.created_at`,
		keyID, publicKey, boundDID, createdAt); err != nil {
		return fmt.Errorf("store: upsert signer key: %w", err)
	}
	return nil
}

// GetSignerKey resolves a key_id to its base64 public key and the DID it is bound to.
func (s *Store) GetSignerKey(ctx context.Context, keyID string) (publicKey, boundDID string, found bool, err error) {
	err = s.pool.QueryRow(ctx,
		`SELECT public_key, bound_did FROM signer_keys WHERE key_id=$1`, keyID).Scan(&publicKey, &boundDID)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", false, nil
	}
	if err != nil {
		return "", "", false, fmt.Errorf("store: get signer key: %w", err)
	}
	return publicKey, boundDID, true, nil
}

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
	if _, err := s.pool.Exec(ctx, `INSERT INTO cmd_idempotency (idem_key, request_hash, status_code, response)
		VALUES ($1,$2,$3,$4) ON CONFLICT (idem_key) DO NOTHING`, key, reqHash, status, string(resp)); err != nil {
		return fmt.Errorf("store: idem put: %w", err)
	}
	return nil
}
