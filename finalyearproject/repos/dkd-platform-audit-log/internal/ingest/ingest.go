// Package ingest is the sink's use-case glue: for every consumed event it builds the append-only
// record, persists it (inbox-deduped), and — per CORRECTION 1 — if a PII-shaped field is present it
// ALSO quarantines a copy and raises a metric, while ALWAYS appending the full record.
package ingest

import (
	"context"
	"time"

	"log/slog"

	"gitlab.com/final-year-project3354127/audit-log-svc/internal/audit"
)

// Store is the persistence port the ingestor needs (satisfied by *store.Postgres).
type Store interface {
	Append(ctx context.Context, rec audit.Record) (inserted bool, err error)
	QuarantinePII(ctx context.Context, rec audit.Record) error
	ParkDLQ(ctx context.Context, e audit.RawEvent, reason string, nowMs int64) error
}

// Metrics is the counter port (satisfied by *obs.Metrics).
type Metrics interface{ Inc(name string) }

// Counter names exposed on /metrics.
const (
	MetricIngested   = "audit_events_ingested_total"
	MetricDeduped    = "audit_events_deduped_total"
	MetricPIIFlagged = "audit_pii_flagged_total"
	MetricParked     = "audit_dlq_parked_total"
)

// Ingestor turns raw spine events into durable, append-only audit rows.
type Ingestor struct {
	store   Store
	metrics Metrics
	log     *slog.Logger
	nowMs   func() int64
}

// New builds an Ingestor. nowMs may be nil (defaults to the wall clock); it is injectable for tests.
func New(store Store, metrics Metrics, log *slog.Logger, nowMs func() int64) *Ingestor {
	if nowMs == nil {
		nowMs = func() int64 { return time.Now().UnixMilli() }
	}
	return &Ingestor{store: store, metrics: metrics, log: log, nowMs: nowMs}
}

// Handle persists one consumed event. It ALWAYS appends (append-all/WORM); PII detection only adds
// a quarantine copy + metric, and a persistence error asks the consumer to park the record. It is
// idempotent: a duplicate event_id is counted as deduped and produces no second row.
func (i *Ingestor) Handle(ctx context.Context, e audit.RawEvent) error {
	rec := audit.BuildRecord(e, i.nowMs())
	inserted, err := i.store.Append(ctx, rec)
	if err != nil {
		return err // consumer will park-and-freeze; never dropped
	}
	if !inserted {
		i.metrics.Inc(MetricDeduped) // duplicate event_id — inbox dedup, effectively-once
		return nil
	}
	i.metrics.Inc(MetricIngested)
	if rec.PIIFlagged {
		i.metrics.Inc(MetricPIIFlagged)
		if qerr := i.store.QuarantinePII(ctx, rec); qerr != nil {
			// The append already succeeded — never fail the pipeline on a quarantine-copy error.
			i.log.Error("PII quarantine copy failed (record still appended)", "event_id", rec.EventID, "err", qerr)
		}
		i.log.Warn("PII-shaped field on spine payload (producer-contract violation); record appended + quarantined",
			"topic", rec.Topic, "event_id", rec.EventID, "pii_fields", rec.PIIFields)
	}
	return nil
}

// Park writes a poison record to the DLQ and reports whether the park succeeded. A false return
// tells the consumer NOT to commit the offset, so the record replays rather than being lost.
func (i *Ingestor) Park(e audit.RawEvent, cause error) bool {
	reason := "unknown"
	if cause != nil {
		reason = cause.Error()
	}
	if err := i.store.ParkDLQ(context.Background(), e, reason, i.nowMs()); err != nil {
		i.log.Error("DLQ park failed; record will replay", "event_id", e.EventID, "err", err)
		return false
	}
	i.metrics.Inc(MetricParked)
	return true
}
