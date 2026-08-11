// Package outbox relays committed custody outbox rows to the Kafka spine (R6).
// At-least-once: rows are marked published only after broker acks; downstream consumers
// dedup on the event_id header (inbox pattern). The relay NEVER auto-creates topics —
// the 59 spine topics are pre-provisioned Published Language.
package outbox

import (
	"context"
	"fmt"
	"time"

	"log/slog"

	"github.com/twmb/franz-go/pkg/kgo"

	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/store"
)

const MetricPublished = "custody_events_published_total"

type Metrics interface{ Inc(name string) }

type Relay struct {
	cl       *kgo.Client
	st       *store.Store
	log      *slog.Logger
	metrics  Metrics
	interval time.Duration
	batch    int
}

func New(brokers []string, st *store.Store, log *slog.Logger, m Metrics) (*Relay, error) {
	if len(brokers) == 0 {
		return nil, fmt.Errorf("outbox: brokers required")
	}
	if st == nil || log == nil || m == nil {
		return nil, fmt.Errorf("outbox: store, logger and metrics are required")
	}
	cl, err := kgo.NewClient(
		kgo.SeedBrokers(brokers...),
		// idempotent producer (default) keeps per-partition ordering; acks=all is the default
	)
	if err != nil {
		return nil, fmt.Errorf("outbox: kafka client: %w", err)
	}
	return &Relay{cl: cl, st: st, log: log, metrics: m, interval: 500 * time.Millisecond, batch: 100}, nil
}

func (r *Relay) Ping(ctx context.Context) error { return r.cl.Ping(ctx) }
func (r *Relay) Close()                         { r.cl.Close() }

// Run drains the outbox until ctx is done. Rows are produced strictly in id order; on the
// first failure the successfully produced prefix is marked and the rest retries next tick.
func (r *Relay) Run(ctx context.Context) {
	t := time.NewTicker(r.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := r.drainOnce(ctx); err != nil {
				r.log.Warn("outbox drain failed; will retry", "err", err)
			}
		}
	}
}

func (r *Relay) drainOnce(ctx context.Context) error {
	rows, err := r.st.FetchUnpublished(ctx, r.batch)
	if err != nil {
		return err
	}
	if len(rows) == 0 {
		return nil
	}
	var done []int64
	for _, row := range rows {
		rec := &kgo.Record{
			Topic: row.Topic,
			Key:   []byte(row.Key),
			Value: row.Payload,
			Headers: []kgo.RecordHeader{
				{Key: "event_id", Value: []byte(row.EventID)},
				{Key: "producer_context", Value: []byte("custody")},
			},
		}
		if err := r.cl.ProduceSync(ctx, rec).FirstErr(); err != nil {
			// mark the safe prefix, keep ordering for the rest
			if mErr := r.st.MarkPublished(ctx, done); mErr != nil {
				r.log.Error("outbox mark-published of prefix failed", "err", mErr)
			}
			return fmt.Errorf("outbox: produce %s (row %d): %w", row.Topic, row.ID, err)
		}
		done = append(done, row.ID)
		r.metrics.Inc(MetricPublished)
	}
	return r.st.MarkPublished(ctx, done)
}
