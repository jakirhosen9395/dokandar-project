// Package outbox owns the transactional-outbox table — rows inserted in
// the same TX as the business change. A relay loop (internal/messaging)
// reads pending rows, publishes to Kafka, then marks sent_at.
package outbox

import (
	"context"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Row struct {
	ID          string
	AggregateID string
	Topic       string
	Payload     []byte
}

type Store struct{ DB *pgxpool.Pool }

// Insert is called from a business TX. payload should already be JSON.
func Insert(ctx context.Context, tx pgx.Tx, topic, aggregateID string, payload []byte) error {
	_, err := tx.Exec(ctx,
		`INSERT INTO outbox (aggregate_id, topic, payload) VALUES ($1::uuid, $2, $3)`,
		aggregateID, topic, payload)
	return err
}

// LoadPending — up to `limit` oldest pending rows.
func (s *Store) LoadPending(ctx context.Context, limit int) ([]Row, error) {
	rows, err := s.DB.Query(ctx,
		`SELECT id::text, aggregate_id::text, topic, payload
		   FROM outbox
		  WHERE sent_at IS NULL
		  ORDER BY created_at
		  LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Row{}
	for rows.Next() {
		var r Row
		if err := rows.Scan(&r.ID, &r.AggregateID, &r.Topic, &r.Payload); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// MarkSent flips sent_at = now() for a single row id.
func (s *Store) MarkSent(ctx context.Context, id string) error {
	_, err := s.DB.Exec(ctx, `UPDATE outbox SET sent_at = now() WHERE id = $1::uuid`, id)
	return err
}

// CountPending — used by /metrics + /data.
func (s *Store) CountPending(ctx context.Context) (int64, error) {
	var n int64
	err := s.DB.QueryRow(ctx, `SELECT count(*) FROM outbox WHERE sent_at IS NULL`).Scan(&n)
	return n, err
}
