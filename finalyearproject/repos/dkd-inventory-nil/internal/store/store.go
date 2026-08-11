// Package store: strong-LOCAL stock records projected from custody (R1 read-side) and the
// G2 reservation seam — row-locked CAS in one local transaction, never a distributed lock,
// never the NIL rollup. All projection applies are inbox-deduped (effectively-once).
package store

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io/fs"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"gitlab.com/final-year-project3354127/inventory-svc/migrations"
)

var (
	ErrNotFound          = errors.New("store: not found")
	ErrInsufficientStock = errors.New("store: insufficient stock")
	ErrBadState          = errors.New("store: illegal reservation state transition")
)

const (
	StateOnHand      = "ON_HAND"
	StateQuarantined = "QUARANTINED"
	StateRetired     = "RETIRED" // split/merged away

	ResHeld     = "HELD"
	ResReleased = "RELEASED"
	ResConsumed = "CONSUMED"
)

type Store struct{ pool *pgxpool.Pool }

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
	lockConn, err := s.pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("store: acquire migration conn: %w", err)
	}
	defer lockConn.Release()
	if _, err := lockConn.Exec(ctx, "SELECT pg_advisory_lock(842005)"); err != nil {
		return fmt.Errorf("store: migration lock: %w", err)
	}
	defer func() { _, _ = lockConn.Exec(context.Background(), "SELECT pg_advisory_unlock(842005)") }()
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
		sqlB, err := fs.ReadFile(migrations.FS, name)
		if err != nil {
			return fmt.Errorf("store: read %s: %w", name, err)
		}
		tx, err := s.pool.Begin(ctx)
		if err != nil {
			return fmt.Errorf("store: begin: %w", err)
		}
		if _, err := tx.Exec(ctx, string(sqlB)); err != nil {
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

type Lot struct {
	PPID     string
	GPID     string
	Holder   string
	Quantity int64
	Unit     string
	State    string
}

func inboxGate(ctx context.Context, tx pgx.Tx, eventID string) (bool, error) {
	tag, err := tx.Exec(ctx,
		`INSERT INTO inbox (event_id) VALUES ($1) ON CONFLICT (event_id) DO NOTHING`, eventID)
	if err != nil {
		return false, fmt.Errorf("store: inbox: %w", err)
	}
	return tag.RowsAffected() == 0, nil
}

func movement(ctx context.Context, tx pgx.Tx, ppid, gpid, eventID, eventHash, eventType, detail string, at int64) error {
	// INV-02: posting_key is the canon hash-linked key INV-<custody eventHash> (chain traceability).
	postingKey := ""
	if eventHash != "" {
		postingKey = "INV-" + eventHash
	}
	if _, err := tx.Exec(ctx, `INSERT INTO stock_movement (ppid, gpid, event_id, event_type, detail, occurred_at_ms, posting_key)
		VALUES ($1,$2,$3,$4,$5,$6,$7)`, ppid, gpid, eventID, eventType, detail, at, postingKey); err != nil {
		return fmt.Errorf("store: movement: %w", err)
	}
	return nil
}

type txFunc func(ctx context.Context, tx pgx.Tx) error

func (s *Store) applyOnce(ctx context.Context, eventID string, fn txFunc) (bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, fmt.Errorf("store: begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	dup, err := inboxGate(ctx, tx, eventID)
	if err != nil {
		return false, err
	}
	if dup {
		return true, nil
	}
	if err := fn(ctx, tx); err != nil {
		return false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return false, fmt.Errorf("store: commit: %w", err)
	}
	return false, nil
}

// SeenOnce records an event with no stock effect (skipped topics).
func (s *Store) SeenOnce(ctx context.Context, eventID string) (bool, error) {
	return s.applyOnce(ctx, eventID, func(context.Context, pgx.Tx) error { return nil })
}

func (s *Store) InitLotOnce(ctx context.Context, eventID, eventHash string, lot Lot, at int64) (bool, error) {
	return s.applyOnce(ctx, eventID, func(ctx context.Context, tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO stock_record (ppid, gpid, holder, quantity, unit, state, updated_at_ms)
			VALUES ($1,$2,$3,$4,$5,$6,$7) ON CONFLICT (ppid) DO NOTHING`,
			lot.PPID, lot.GPID, lot.Holder, lot.Quantity, lot.Unit, StateOnHand, at); err != nil {
			return fmt.Errorf("store: init lot: %w", err)
		}
		return movement(ctx, tx, lot.PPID, lot.GPID, eventID, eventHash, "CustodyInitialized", "+ON_HAND "+lot.Holder, at)
	})
}

func (s *Store) TransferOnce(ctx context.Context, eventID, eventHash, ppid, toHolder string, at int64) (bool, error) {
	return s.applyOnce(ctx, eventID, func(ctx context.Context, tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE stock_record SET holder=$2, updated_at_ms=$3 WHERE ppid=$1`, ppid, toHolder, at)
		if err != nil {
			return fmt.Errorf("store: transfer: %w", err)
		}
		detail := "holder->" + toHolder
		if tag.RowsAffected() == 0 {
			detail = "UNKNOWN PPID (projection gap) holder->" + toHolder
		}
		return movement(ctx, tx, ppid, "", eventID, eventHash, "CustodyTransferred", detail, at)
	})
}

func (s *Store) SplitOnce(ctx context.Context, eventID, eventHash, parentPpid string, children []Lot, at int64) (bool, error) {
	return s.applyOnce(ctx, eventID, func(ctx context.Context, tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `UPDATE stock_record SET state=$2, updated_at_ms=$3 WHERE ppid=$1`,
			parentPpid, StateRetired, at); err != nil {
			return fmt.Errorf("store: retire parent: %w", err)
		}
		for _, c := range children {
			if _, err := tx.Exec(ctx, `INSERT INTO stock_record (ppid, gpid, holder, quantity, unit, state, updated_at_ms)
				VALUES ($1,$2,$3,$4,$5,$6,$7) ON CONFLICT (ppid) DO NOTHING`,
				c.PPID, c.GPID, c.Holder, c.Quantity, c.Unit, StateOnHand, at); err != nil {
				return fmt.Errorf("store: split child: %w", err)
			}
		}
		return movement(ctx, tx, parentPpid, "", eventID, eventHash, "CustodySplit", fmt.Sprintf("-> %d children", len(children)), at)
	})
}

func (s *Store) MergeOnce(ctx context.Context, eventID, eventHash string, sourcePpids []string, newLot Lot, at int64) (bool, error) {
	return s.applyOnce(ctx, eventID, func(ctx context.Context, tx pgx.Tx) error {
		for _, p := range sourcePpids {
			if _, err := tx.Exec(ctx, `UPDATE stock_record SET state=$2, updated_at_ms=$3 WHERE ppid=$1`,
				p, StateRetired, at); err != nil {
				return fmt.Errorf("store: retire source: %w", err)
			}
		}
		if _, err := tx.Exec(ctx, `INSERT INTO stock_record (ppid, gpid, holder, quantity, unit, state, updated_at_ms)
			VALUES ($1,$2,$3,$4,$5,$6,$7) ON CONFLICT (ppid) DO NOTHING`,
			newLot.PPID, newLot.GPID, newLot.Holder, newLot.Quantity, newLot.Unit, StateOnHand, at); err != nil {
			return fmt.Errorf("store: merged lot: %w", err)
		}
		return movement(ctx, tx, newLot.PPID, newLot.GPID, eventID, eventHash, "CustodyMerged",
			fmt.Sprintf("<- %d sources", len(sourcePpids)), at)
	})
}

func (s *Store) QuarantineOnce(ctx context.Context, eventID, eventHash string, ppids []string, at int64) (bool, error) {
	return s.applyOnce(ctx, eventID, func(ctx context.Context, tx pgx.Tx) error {
		for _, p := range ppids {
			if _, err := tx.Exec(ctx, `UPDATE stock_record SET state=$2, updated_at_ms=$3 WHERE ppid=$1`,
				p, StateQuarantined, at); err != nil {
				return fmt.Errorf("store: quarantine: %w", err)
			}
			if err := movement(ctx, tx, p, "", eventID, eventHash, "ProductRecalled", "QUARANTINED", at); err != nil {
				return err
			}
		}
		return nil
	})
}

type Reservation struct {
	ResID    string `json:"resId"`
	GPID     string `json:"gpid"`
	Holder   string `json:"holder"`
	Quantity int64  `json:"quantity"`
	State    string `json:"state"`
	IdemKey  string `json:"-"`
}

func uuidv7() string {
	var b [16]byte
	ms := uint64(time.Now().UnixMilli())
	b[0], b[1], b[2] = byte(ms>>40), byte(ms>>32), byte(ms>>24)
	b[3], b[4], b[5] = byte(ms>>16), byte(ms>>8), byte(ms)
	if _, err := rand.Read(b[6:]); err != nil {
		panic("crypto/rand unavailable: " + err.Error())
	}
	b[6] = 0x70 | (b[6] & 0x0f)
	b[8] = 0x80 | (b[8] & 0x3f)
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// Reserve is the G2 strong-LOCAL seam: row-locks the holder's ON_HAND lots, computes
// available = onHand - HELD, and inserts the reservation — ONE local transaction, idempotent
// on idemKey (replay returns the stored reservation). NEVER consults the NIL rollup.
func (s *Store) Reserve(ctx context.Context, idemKey, gpid, holder string, qty, at int64) (Reservation, error) {
	if qty <= 0 {
		return Reservation{}, fmt.Errorf("store: quantity must be positive")
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Reservation{}, fmt.Errorf("store: begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// H3: serialize ALL reserves for this (gpid,holder) — including the zero-lot case where
	// FOR UPDATE acquires no row locks — against each other and concurrent lot inserts.
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, gpid+"|"+holder); err != nil {
		return Reservation{}, fmt.Errorf("store: reserve lock: %w", err)
	}

	var existing Reservation
	err = tx.QueryRow(ctx, `SELECT res_id, gpid, holder, quantity, state FROM reservation WHERE idem_key=$1`, idemKey).
		Scan(&existing.ResID, &existing.GPID, &existing.Holder, &existing.Quantity, &existing.State)
	if err == nil {
		return existing, nil // idempotent replay
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return Reservation{}, fmt.Errorf("store: idem lookup: %w", err)
	}

	rows, err := tx.Query(ctx, `SELECT quantity FROM stock_record
		WHERE gpid=$1 AND holder=$2 AND state=$3 FOR UPDATE`, gpid, holder, StateOnHand)
	if err != nil {
		return Reservation{}, fmt.Errorf("store: lock lots: %w", err)
	}
	var onHand int64
	for rows.Next() {
		var q int64
		if err := rows.Scan(&q); err != nil {
			rows.Close()
			return Reservation{}, fmt.Errorf("store: scan lot: %w", err)
		}
		onHand += q
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return Reservation{}, fmt.Errorf("store: lots iter: %w", err)
	}
	var held int64
	if err := tx.QueryRow(ctx, `SELECT COALESCE(SUM(quantity),0) FROM reservation
		WHERE gpid=$1 AND holder=$2 AND state=$3`, gpid, holder, ResHeld).Scan(&held); err != nil {
		return Reservation{}, fmt.Errorf("store: held sum: %w", err)
	}
	if qty > onHand-held {
		return Reservation{}, ErrInsufficientStock
	}
	r := Reservation{ResID: "RES-" + uuidv7(), GPID: gpid, Holder: holder, Quantity: qty, State: ResHeld}
	tag, err := tx.Exec(ctx, `INSERT INTO reservation (res_id, gpid, holder, quantity, state, idem_key, created_at_ms, updated_at_ms)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$7) ON CONFLICT (idem_key) DO NOTHING`, r.ResID, gpid, holder, qty, ResHeld, idemKey, at)
	if err != nil {
		return Reservation{}, fmt.Errorf("store: insert reservation: %w", err)
	}
	if tag.RowsAffected() == 0 { // H1: lost a same-idem-key race — return the winner's row
		if err := tx.QueryRow(ctx, `SELECT res_id, gpid, holder, quantity, state FROM reservation WHERE idem_key=$1`, idemKey).
			Scan(&r.ResID, &r.GPID, &r.Holder, &r.Quantity, &r.State); err != nil {
			return Reservation{}, fmt.Errorf("store: idem read-back: %w", err)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return Reservation{}, fmt.Errorf("store: commit: %w", err)
	}
	return r, nil
}

// Transition moves a reservation HELD->RELEASED or HELD->CONSUMED, idempotently.
func (s *Store) Transition(ctx context.Context, resID, to string, at int64) (Reservation, error) {
	if to != ResReleased && to != ResConsumed {
		return Reservation{}, ErrBadState
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Reservation{}, fmt.Errorf("store: begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	tag, err := tx.Exec(ctx, `UPDATE reservation SET state=$2, updated_at_ms=$3
		WHERE res_id=$1 AND state=$4`, resID, to, at, ResHeld)
	if err != nil {
		return Reservation{}, fmt.Errorf("store: transition: %w", err)
	}
	var r Reservation
	err = tx.QueryRow(ctx, `SELECT res_id, gpid, holder, quantity, state FROM reservation WHERE res_id=$1`, resID).
		Scan(&r.ResID, &r.GPID, &r.Holder, &r.Quantity, &r.State)
	if errors.Is(err, pgx.ErrNoRows) {
		return Reservation{}, ErrNotFound
	}
	if err != nil {
		return Reservation{}, fmt.Errorf("store: read reservation: %w", err)
	}
	if tag.RowsAffected() == 0 && r.State != to {
		return r, ErrBadState // e.g. RELEASED -> CONSUMED
	}
	if err := tx.Commit(ctx); err != nil {
		return Reservation{}, fmt.Errorf("store: commit: %w", err)
	}
	return r, nil
}

type LocalStock struct {
	GPID      string `json:"gpid"`
	Holder    string `json:"holder"`
	OnHand    int64  `json:"onHand"`
	Held      int64  `json:"held"`
	Available int64  `json:"available"`
}

// Local reads the strong-LOCAL stock position (reservation-critical reads land HERE, never NIL).
func (s *Store) Local(ctx context.Context, gpid, holder string) (LocalStock, error) {
	ls := LocalStock{GPID: gpid, Holder: holder}
	if err := s.pool.QueryRow(ctx, `SELECT COALESCE(SUM(quantity),0) FROM stock_record
		WHERE gpid=$1 AND holder=$2 AND state=$3`, gpid, holder, StateOnHand).Scan(&ls.OnHand); err != nil {
		return ls, fmt.Errorf("store: on-hand: %w", err)
	}
	if err := s.pool.QueryRow(ctx, `SELECT COALESCE(SUM(quantity),0) FROM reservation
		WHERE gpid=$1 AND holder=$2 AND state=$3`, gpid, holder, ResHeld).Scan(&ls.Held); err != nil {
		return ls, fmt.Errorf("store: held: %w", err)
	}
	ls.Available = ls.OnHand - ls.Held
	return ls, nil
}

type NILBreakdown struct {
	Holder   string `json:"location"`
	Quantity int64  `json:"quantity"`
}

type NILRollup struct {
	GPID        string         `json:"gpid"`
	Total       int64          `json:"totalQuantity"`
	HolderCount int64          `json:"holderCount"`
	Breakdown   []NILBreakdown `json:"locationBreakdown"`
	ComputedAt  int64          `json:"computedAt"`
	LagMs       int64          `json:"lagMs"`
}

// NIL computes the national rollup on read (fresher than the <=60s SLO; asOf carried in meta).
func (s *Store) NIL(ctx context.Context, gpid string, at int64) (NILRollup, error) {
	out := NILRollup{GPID: gpid, ComputedAt: at, LagMs: 0}
	rows, err := s.pool.Query(ctx, `SELECT holder, SUM(quantity) FROM stock_record
		WHERE gpid=$1 AND state=$2 GROUP BY holder ORDER BY holder`, gpid, StateOnHand)
	if err != nil {
		return out, fmt.Errorf("store: nil rollup: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var b NILBreakdown
		if err := rows.Scan(&b.Holder, &b.Quantity); err != nil {
			return out, fmt.Errorf("store: scan rollup: %w", err)
		}
		out.Breakdown = append(out.Breakdown, b)
		out.Total += b.Quantity
		out.HolderCount++
	}
	return out, rows.Err()
}
