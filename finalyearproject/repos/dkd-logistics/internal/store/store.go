// Package store — shipments + R6 spine mechanics on dkd_logistics (advisory lock 842009).
// Delivery/pickup addresses live ONLY here, never in a spine payload (PII, FR-MKT-004).
package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"gitlab.com/final-year-project3354127/logistics-svc/internal/logistics"
)

const advisoryLockKey = 842009

var (
	ErrNotFound   = errors.New("store: not found")
	ErrConflict   = errors.New("store: illegal transition")
	ErrIdemReplay = errors.New("store: duplicate command")
)

type Shipment struct {
	SHP             string          `json:"shp"`
	ReferenceID     string          `json:"referenceId"`
	ReferenceType   string          `json:"referenceType"`
	Status          logistics.Status `json:"status"`
	AssignedRider   *string         `json:"assignedRiderDid,omitempty"`
	PodPhotoURL     *string         `json:"podPhotoUrl,omitempty"`
	Reason          *string         `json:"reason,omitempty"`
	PickupAddress   json.RawMessage `json:"pickupAddress,omitempty"`
	DeliveryAddress json.RawMessage `json:"-"` // PII: exposed only via the tracking/detail API, never events
	CreatedAt       int64           `json:"createdAt"`
	UpdatedAt       int64           `json:"updatedAt"`
	DeliveredAt     *int64          `json:"deliveredAt,omitempty"`
}

type OutboxRow struct {
	ID      int64
	EventID string
	Topic   string
	Key     string
	Payload []byte
}

type Store struct{ pool *pgxpool.Pool }

func Open(ctx context.Context, dsn string) (*Store, error) {
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return nil, err
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	return &Store{pool: pool}, nil
}

func (s *Store) Close()                          { s.pool.Close() }
func (s *Store) Ping(ctx context.Context) error  { return s.pool.Ping(ctx) }

var migrations = []string{`
CREATE TABLE IF NOT EXISTS shipments (
  shp TEXT PRIMARY KEY,
  reference_id TEXT NOT NULL,
  reference_type TEXT NOT NULL CHECK (reference_type IN ('ORDER','TRADE')),
  status TEXT NOT NULL CHECK (status IN ('PENDING','RIDER_ASSIGNED','PICKED_UP','DELIVERED','CANCELLED','FAILED')),
  assigned_rider_did TEXT,
  pod_photo_url TEXT,
  reason TEXT,
  pickup_address JSONB,
  delivery_address JSONB,
  idem_key TEXT UNIQUE,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  delivered_at BIGINT,
  UNIQUE (reference_id, reference_type)
)`, `
CREATE TABLE IF NOT EXISTS outbox (
  id BIGSERIAL PRIMARY KEY,
  event_id TEXT NOT NULL UNIQUE,
  topic TEXT NOT NULL,
  partition_key TEXT NOT NULL,
  payload JSONB NOT NULL,
  occurred_at BIGINT NOT NULL,
  published_at BIGINT
)`, `
CREATE INDEX IF NOT EXISTS outbox_unpublished_idx ON outbox(id) WHERE published_at IS NULL`, `
CREATE TABLE IF NOT EXISTS inbox (
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
)`, `
-- LOG-04: GPS telemetry / live-tracking plane (append-only location points per shipment). A
-- TimescaleDB hypertable is the future-wave upgrade; a time-indexed table serves the MVP.
CREATE TABLE IF NOT EXISTS shipment_location (
  id          BIGSERIAL PRIMARY KEY,
  shp         TEXT   NOT NULL,
  lat         DOUBLE PRECISION NOT NULL,
  lng         DOUBLE PRECISION NOT NULL,
  recorded_at BIGINT NOT NULL
)`, `
CREATE INDEX IF NOT EXISTS shipment_location_shp_idx ON shipment_location(shp, recorded_at DESC)`}

// LocationPoint is one GPS telemetry sample on a shipment's track (LOG-04).
type LocationPoint struct {
	Lat        float64 `json:"lat"`
	Lng        float64 `json:"lng"`
	RecordedAt int64   `json:"recordedAt"`
}

// RecordLocation appends a GPS point for a shipment (LOG-04 live tracking).
func (s *Store) RecordLocation(ctx context.Context, shp string, lat, lng float64, at int64) error {
	_, err := s.pool.Exec(ctx,
		`INSERT INTO shipment_location (shp, lat, lng, recorded_at) VALUES ($1,$2,$3,$4)`, shp, lat, lng, at)
	return err
}

// Track returns the most recent GPS points for a shipment (newest first).
func (s *Store) Track(ctx context.Context, shp string, limit int) ([]LocationPoint, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	rows, err := s.pool.Query(ctx,
		`SELECT lat, lng, recorded_at FROM shipment_location WHERE shp=$1 ORDER BY recorded_at DESC LIMIT $2`, shp, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []LocationPoint
	for rows.Next() {
		var p LocationPoint
		if err := rows.Scan(&p.Lat, &p.Lng, &p.RecordedAt); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *Store) Migrate(ctx context.Context) error {
	cx, err := s.pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer cx.Release()
	if _, err := cx.Exec(ctx, "SELECT pg_advisory_lock($1)", advisoryLockKey); err != nil {
		return err
	}
	defer func() { _, _ = cx.Exec(ctx, "SELECT pg_advisory_unlock($1)", advisoryLockKey) }()
	for _, m := range migrations {
		if _, err := cx.Exec(ctx, m); err != nil {
			return fmt.Errorf("store: migrate: %w", err)
		}
	}
	return nil
}

func isUnique(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

// CreateShipment: idempotent on idem_key AND on (reference_id, reference_type) — a duplicate
// command or a duplicate order event returns the existing shipment (created=false).
func (s *Store) CreateShipment(ctx context.Context, idemKey, refID, refType string,
	pickup, delivery json.RawMessage, mkEvent func(shp string) OutboxRow, now int64) (Shipment, bool, error) {
	shp := logistics.NewSHP()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Shipment{}, false, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	_, err = tx.Exec(ctx, `INSERT INTO shipments
	  (shp, reference_id, reference_type, status, pickup_address, delivery_address, idem_key, created_at, updated_at)
	  VALUES ($1,$2,$3,'PENDING',$4,$5,$6,$7,$7)`,
		shp, refID, refType, pickup, delivery, idemKey, now)
	if err != nil {
		if isUnique(err) {
			existing, gErr := s.byReferenceOrIdem(ctx, refID, refType, idemKey)
			if gErr != nil {
				return Shipment{}, false, gErr
			}
			return existing, false, nil
		}
		return Shipment{}, false, err
	}
	if err := insertOutbox(ctx, tx, mkEvent(shp), shp, now); err != nil {
		return Shipment{}, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Shipment{}, false, err
	}
	created, err := s.Get(ctx, shp)
	return created, true, err
}

// Transition CAS: from-set guarded; writes optional fields; appends the outbox event atomically.
func (s *Store) Transition(ctx context.Context, shp string, from []logistics.Status, to logistics.Status,
	set map[string]any, outboxEvent OutboxRow, now int64) (Shipment, error) {
	cur, err := s.Get(ctx, shp)
	if err != nil {
		return Shipment{}, err
	}
	// LOG-02: a transition to the state the shipment is ALREADY in is an idempotent replay (e.g. a
	// retried pickup/pod) — return the current shipment (2xx) instead of 409 bad_transition; the
	// original command already emitted its event, so we do not re-emit.
	if cur.Status == to {
		return cur, nil
	}
	if !logistics.CanTransition(cur.Status, to) {
		return Shipment{}, fmt.Errorf("%w: %s -> %s", ErrConflict, cur.Status, to)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Shipment{}, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	fromStrs := make([]string, len(from))
	for i, f := range from {
		fromStrs[i] = string(f)
	}
	rider, pod, reason := set["assigned_rider_did"], set["pod_photo_url"], set["reason"]
	deliveredAt := set["delivered_at"]
	tag, err := tx.Exec(ctx, `UPDATE shipments SET status=$1,
	  assigned_rider_did=COALESCE($2, assigned_rider_did),
	  pod_photo_url=COALESCE($3, pod_photo_url),
	  reason=COALESCE($4, reason),
	  delivered_at=COALESCE($5, delivered_at),
	  updated_at=$6 WHERE shp=$7 AND status = ANY($8)`,
		string(to), rider, pod, reason, deliveredAt, now, shp, fromStrs)
	if err != nil {
		return Shipment{}, err
	}
	if tag.RowsAffected() != 1 {
		return Shipment{}, fmt.Errorf("%w: concurrent transition on %s", ErrConflict, shp)
	}
	if err := insertOutbox(ctx, tx, outboxEvent, shp, now); err != nil {
		return Shipment{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Shipment{}, err
	}
	return s.Get(ctx, shp)
}

func (s *Store) Get(ctx context.Context, shp string) (Shipment, error) {
	return scanShipment(s.pool.QueryRow(ctx,
		`SELECT shp, reference_id, reference_type, status, assigned_rider_did, pod_photo_url,
		 reason, pickup_address, delivery_address, created_at, updated_at, delivered_at
		 FROM shipments WHERE shp=$1`, shp))
}

func (s *Store) ByReference(ctx context.Context, refID, refType string) (Shipment, error) {
	return scanShipment(s.pool.QueryRow(ctx,
		`SELECT shp, reference_id, reference_type, status, assigned_rider_did, pod_photo_url,
		 reason, pickup_address, delivery_address, created_at, updated_at, delivered_at
		 FROM shipments WHERE reference_id=$1 AND reference_type=$2`, refID, refType))
}

func (s *Store) byReferenceOrIdem(ctx context.Context, refID, refType, idemKey string) (Shipment, error) {
	sh, err := s.ByReference(ctx, refID, refType)
	if err == nil {
		return sh, nil
	}
	return scanShipment(s.pool.QueryRow(ctx,
		`SELECT shp, reference_id, reference_type, status, assigned_rider_did, pod_photo_url,
		 reason, pickup_address, delivery_address, created_at, updated_at, delivered_at
		 FROM shipments WHERE idem_key=$1`, idemKey))
}

func scanShipment(row pgx.Row) (Shipment, error) {
	var sh Shipment
	var status string
	err := row.Scan(&sh.SHP, &sh.ReferenceID, &sh.ReferenceType, &status, &sh.AssignedRider,
		&sh.PodPhotoURL, &sh.Reason, &sh.PickupAddress, &sh.DeliveryAddress,
		&sh.CreatedAt, &sh.UpdatedAt, &sh.DeliveredAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Shipment{}, ErrNotFound
	}
	if err != nil {
		return Shipment{}, err
	}
	sh.Status = logistics.Status(status)
	return sh, nil
}

func insertOutbox(ctx context.Context, tx pgx.Tx, ev OutboxRow, key string, now int64) error {
	if ev.Topic == "" {
		return nil
	}
	if ev.Key == "" {
		ev.Key = key
	}
	_, err := tx.Exec(ctx,
		`INSERT INTO outbox(event_id, topic, partition_key, payload, occurred_at) VALUES ($1,$2,$3,$4,$5)`,
		ev.EventID, ev.Topic, ev.Key, ev.Payload, now)
	return err
}

// ConsumeOnce runs fn only if eventID is fresh; inbox mark + effects commit atomically.
func (s *Store) ConsumeOnce(ctx context.Context, eventID, topic string, now int64,
	fn func(pgx.Tx) error) (bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	tag, err := tx.Exec(ctx,
		`INSERT INTO inbox(event_id, topic, processed_at) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING`,
		eventID, topic, now)
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

// ParkDLQ quarantines a poison consumer record after its bounded inline retries are exhausted
// (LOG-03), so the partition can advance instead of blocking forever. Idempotent on event_id.
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

func (s *Store) FetchUnpublished(ctx context.Context, limit int) ([]OutboxRow, error) {
	rows, err := s.pool.Query(ctx, `SELECT id, event_id, topic, partition_key, payload
	  FROM outbox WHERE published_at IS NULL ORDER BY id LIMIT $1`, limit)
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
	_, err := s.pool.Exec(ctx,
		`UPDATE outbox SET published_at = (EXTRACT(EPOCH FROM now())*1000)::BIGINT WHERE id = ANY($1)`, ids)
	return err
}

// --- event-path variants: run inside a ConsumeOnce transaction ---

// CreateShipmentTx inserts a PENDING shipment from an OrderPlaced event; duplicate
// references are no-ops (saga replay safe). Returns the shp and whether it was created.
func (s *Store) CreateShipmentTx(ctx context.Context, tx pgx.Tx, refID, refType string,
	pickup, delivery json.RawMessage, mkEvent func(shp string) OutboxRow, now int64) (string, bool, error) {
	shp := logistics.NewSHP()
	tag, err := tx.Exec(ctx, `INSERT INTO shipments
	  (shp, reference_id, reference_type, status, pickup_address, delivery_address, created_at, updated_at)
	  VALUES ($1,$2,$3,'PENDING',$4,$5,$6,$6)
	  ON CONFLICT (reference_id, reference_type) DO NOTHING`,
		shp, refID, refType, pickup, delivery, now)
	if err != nil {
		return "", false, err
	}
	if tag.RowsAffected() == 0 {
		return "", false, nil
	}
	return shp, true, insertOutbox(ctx, tx, mkEvent(shp), shp, now)
}

// CancelByReferenceTx: OrderCancelled saga step. Missing/terminal shipments are no-ops
// ("continue, no compensation" — DM Saga 2). Returns the cancelled shp ("" if no-op).
func (s *Store) CancelByReferenceTx(ctx context.Context, tx pgx.Tx, refID, refType, reason string,
	mkEvent func(shp string) OutboxRow, now int64) (string, error) {
	var shp, status string
	err := tx.QueryRow(ctx,
		`SELECT shp, status FROM shipments WHERE reference_id=$1 AND reference_type=$2 FOR UPDATE`,
		refID, refType).Scan(&shp, &status)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	if !logistics.CanTransition(logistics.Status(status), logistics.StatusCancelled) {
		return "", nil
	}
	if _, err := tx.Exec(ctx,
		`UPDATE shipments SET status='CANCELLED', reason=$1, updated_at=$2 WHERE shp=$3`,
		reason, now, shp); err != nil {
		return "", err
	}
	return shp, insertOutbox(ctx, tx, mkEvent(shp), shp, now)
}
