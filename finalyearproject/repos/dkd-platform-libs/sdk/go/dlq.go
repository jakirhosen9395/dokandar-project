package dkdplatform

import (
	"context"
	"fmt"
)

// DlqRecord is a poison event routed to the dead-letter store. AggregateKey is
// the ordering key that gets frozen (SA-MSG-10 park-and-freeze).
type DlqRecord struct {
	EventID      string
	Topic        string
	Key          string
	Payload      []byte
	Error        string
	AggregateKey string
}

// Dlq is the park-and-freeze adapter. A poison money/custody/inventory event is
// NEVER silently dropped: it is parked, and only its own AggregateKey freezes —
// other keys on the same topic keep progressing. Stateless; zero-value usable.
type Dlq struct{}

// Park records a poison event and freezes its aggregate key.
func (Dlq) Park(ctx context.Context, db DB, r DlqRecord) error {
	if db == nil {
		return fmt.Errorf("dlq: nil db handle")
	}
	if r.EventID == "" || r.AggregateKey == "" {
		return fmt.Errorf("dlq: eventId and aggregateKey are required")
	}
	_, err := db.ExecContext(ctx,
		`INSERT INTO dlq (event_id, topic, key, payload, error, aggregate_key, parked_at)
		 VALUES ($1,$2,$3,$4,$5,$6,now())`,
		r.EventID, r.Topic, r.Key, r.Payload, r.Error, r.AggregateKey)
	if err != nil {
		return fmt.Errorf("dlq: park %s: %w", r.EventID, err)
	}
	return nil
}

// IsKeyParked reports whether the given aggregate key is currently frozen. The
// consumer checks this before processing an event so a frozen key stays halted
// while sibling keys advance.
func (Dlq) IsKeyParked(ctx context.Context, db DB, aggregateKey string) (bool, error) {
	if db == nil {
		return false, fmt.Errorf("dlq: nil db handle")
	}
	rows, err := db.QueryContext(ctx,
		`SELECT 1 FROM dlq WHERE aggregate_key = $1 LIMIT 1`, aggregateKey)
	if err != nil {
		return false, fmt.Errorf("dlq: is-key-parked %s: %w", aggregateKey, err)
	}
	defer rows.Close()
	found := rows.Next()
	if err := rows.Err(); err != nil {
		return false, fmt.Errorf("dlq: is-key-parked %s: %w", aggregateKey, err)
	}
	return found, nil
}
