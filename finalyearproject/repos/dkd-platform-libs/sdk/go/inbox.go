package dkdplatform

import (
	"context"
	"fmt"
)

// Inbox is the consumer-side dedup half of SA-CONV-QUARTET. AlreadyProcessed and
// MarkProcessed MUST run in the SAME transaction as the side effect they guard,
// so a consumer that crashes after the side effect but before the mark replays
// safely (effectively-once). Stateless; construct with a zero value.
type Inbox struct{}

// AlreadyProcessed reports whether (consumer, eventId) has been recorded. Run it
// inside the handler's transaction, before applying the side effect.
func (Inbox) AlreadyProcessed(ctx context.Context, tx DB, consumer, eventID string) (bool, error) {
	if tx == nil {
		return false, fmt.Errorf("inbox: nil tx handle")
	}
	rows, err := tx.QueryContext(ctx,
		`SELECT 1 FROM inbox WHERE consumer = $1 AND event_id = $2`, consumer, eventID)
	if err != nil {
		return false, fmt.Errorf("inbox: lookup %s/%s: %w", consumer, eventID, err)
	}
	defer rows.Close()
	found := rows.Next()
	if err := rows.Err(); err != nil {
		return false, fmt.Errorf("inbox: lookup %s/%s: %w", consumer, eventID, err)
	}
	return found, nil
}

// MarkProcessed records (consumer, eventId) in the handler's transaction. ON
// CONFLICT DO NOTHING keeps it idempotent under concurrent redelivery.
func (Inbox) MarkProcessed(ctx context.Context, tx DB, consumer, eventID string) error {
	if tx == nil {
		return fmt.Errorf("inbox: nil tx handle")
	}
	if consumer == "" || eventID == "" {
		return fmt.Errorf("inbox: consumer and eventId are required")
	}
	_, err := tx.ExecContext(ctx,
		`INSERT INTO inbox (consumer, event_id, processed_at)
		 VALUES ($1,$2,now())
		 ON CONFLICT (consumer, event_id) DO NOTHING`, consumer, eventID)
	if err != nil {
		return fmt.Errorf("inbox: mark %s/%s: %w", consumer, eventID, err)
	}
	return nil
}
