package dkdplatform

import (
	"context"
	"fmt"
	"strconv"
	"strings"
)

// OutboxRecord is the payload of a single event to emit. It is inserted into the
// outbox in the SAME transaction as the aggregate state change (effectively-once
// producer half of SA-CONV-QUARTET).
type OutboxRecord struct {
	EventID      string
	Topic        string
	Key          string
	Payload      []byte
	OccurredAtMs int64
}

// Outbox is the transactional-outbox writer. It is stateless; construct with a
// zero value: var ob dkdplatform.Outbox.
type Outbox struct{}

// Enqueue inserts one outbox row using a CALLER-PROVIDED transaction handle so
// the event is committed atomically with the aggregate write. ON CONFLICT
// (event_id) DO NOTHING makes a re-enqueue of the same event a no-op (idempotent
// producer). Returns nil on both first insert and duplicate.
func (Outbox) Enqueue(ctx context.Context, tx DB, r OutboxRecord) error {
	if tx == nil {
		return fmt.Errorf("outbox: nil tx handle")
	}
	if r.EventID == "" || r.Topic == "" {
		return fmt.Errorf("outbox: eventId and topic are required")
	}
	_, err := tx.ExecContext(ctx,
		`INSERT INTO outbox (event_id, topic, key, payload, occurred_at_ms)
		 VALUES ($1,$2,$3,$4,$5)
		 ON CONFLICT (event_id) DO NOTHING`,
		r.EventID, r.Topic, r.Key, r.Payload, r.OccurredAtMs)
	if err != nil {
		return fmt.Errorf("outbox: enqueue %s: %w", r.EventID, err)
	}
	return nil
}

// OutboxRow is a fetched-but-unpublished outbox row for the publisher loop.
type OutboxRow struct {
	ID           int64
	EventID      string
	Topic        string
	Key          string
	Payload      []byte
	OccurredAtMs int64
}

// Header is a single Kafka record header (name + bytes). Kept driver-agnostic so
// the concrete producer (franz-go, sarama, …) maps it onto its own record type.
type Header struct {
	Key   string
	Value []byte
}

// OutboxRelay drains unpublished rows and stamps them published after the broker
// acks (at-least-once; consumers dedup via the inbox). ProducerContext is the
// emitting bounded context (e.g. "custody", "finance") stamped on every record.
type OutboxRelay struct {
	ProducerContext string
}

// FetchUnpublished returns up to limit unpublished rows in id order (partial
// index outbox_unpublished_idx). Uses the pool/connection, not a tx.
func (OutboxRelay) FetchUnpublished(ctx context.Context, db DB, limit int) ([]OutboxRow, error) {
	if db == nil {
		return nil, fmt.Errorf("outbox: nil db handle")
	}
	if limit <= 0 {
		limit = 100
	}
	rows, err := db.QueryContext(ctx,
		`SELECT id, event_id, topic, key, payload, occurred_at_ms
		 FROM outbox WHERE published_at IS NULL ORDER BY id LIMIT $1`, limit)
	if err != nil {
		return nil, fmt.Errorf("outbox: fetch unpublished: %w", err)
	}
	defer rows.Close()
	var out []OutboxRow
	for rows.Next() {
		var r OutboxRow
		if err := rows.Scan(&r.ID, &r.EventID, &r.Topic, &r.Key, &r.Payload, &r.OccurredAtMs); err != nil {
			return nil, fmt.Errorf("outbox: scan row: %w", err)
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// MarkPublished stamps published_at on the given ids. Called only after the
// broker has acked those records. A nil/empty id set is a no-op.
func (OutboxRelay) MarkPublished(ctx context.Context, db DB, ids []int64) error {
	if len(ids) == 0 {
		return nil
	}
	if db == nil {
		return fmt.Errorf("outbox: nil db handle")
	}
	ph := make([]string, len(ids))
	args := make([]any, len(ids))
	for i, id := range ids {
		ph[i] = "$" + strconv.Itoa(i+1)
		args[i] = id
	}
	q := `UPDATE outbox SET published_at = now() WHERE id IN (` + strings.Join(ph, ",") + `)`
	if _, err := db.ExecContext(ctx, q, args...); err != nil {
		return fmt.Errorf("outbox: mark published: %w", err)
	}
	return nil
}

// Headers builds the record headers the relay injects on publish: a
// 'traceparent' (stub-safe — passed through only when present), the immutable
// 'event_id' (the inbox dedup key), and 'producer_context'. R6: payloads carry
// canonical IDs only; these headers carry no PII.
func (r OutboxRelay) Headers(row OutboxRow, traceparent string) []Header {
	hs := make([]Header, 0, 3)
	if traceparent != "" {
		hs = append(hs, Header{Key: "traceparent", Value: []byte(traceparent)})
	}
	hs = append(hs,
		Header{Key: "event_id", Value: []byte(row.EventID)},
		Header{Key: "producer_context", Value: []byte(r.ProducerContext)},
	)
	return hs
}
