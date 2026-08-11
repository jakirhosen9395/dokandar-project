// Package projection maintains the M5 intra-context read model:
// ActivePassportCountByGpid, fed by custody.passport.* spine events. It exists ONLY to guard
// DeprecateProduct (no cross-context store reads — R1/R6). The projection is rebuildable by
// replaying the custody topics with a fresh consumer group.
package projection

import (
	"context"
	"encoding/json"

	"log/slog"

	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"

	"gitlab.com/final-year-project3354127/catalog-svc/internal/consumer"
)

const (
	MetricApplied = "catalog_m5_events_applied_total"
	MetricDeduped = "catalog_m5_events_deduped_total"
	MetricSkipped = "catalog_m5_events_skipped_total"
	MetricParked  = "catalog_m5_events_parked_total"
)

type Store interface {
	InboxSeen(ctx context.Context, eventID string) (bool, error)
	// ApplyPassportDeltaOnce applies inbox dedup + count delta in ONE transaction (HIGH-3 fix):
	// a failed delta rolls back the inbox row too, so replays can reprocess.
	ApplyPassportDeltaOnce(ctx context.Context, eventID, gpid string, delta int64) (dup bool, err error)
}

type Metrics interface{ Inc(name string) }

type M5 struct {
	st  Store
	m   Metrics
	log *slog.Logger
}

func New(st Store, m Metrics, log *slog.Logger) *M5 { return &M5{st: st, m: m, log: log} }

// Topics returns the canonical consume-set for the projection.
func Topics() []string {
	return []string{
		dkd.TopicCustodyPassportCustodyInitializedV1,
		dkd.TopicCustodyPassportCustodyTransferredV1,
		dkd.TopicCustodyPassportCustodySplitV1,
		dkd.TopicCustodyPassportCustodyMergedV1,
		dkd.TopicCustodyPassportProductRecalledV1,
		dkd.TopicCustodyPassportCustodialSignedV1,
	}
}

// Handle applies one custody event to the projection with inbox dedup.
// Payload schemas are NEEDS-INFO in the frozen contracts: only CustodyInitialized carrying a
// "gpid" field mutates the count today; every other event is a typed extension point (skipped,
// metered, logged) until Phase-2 schemas land — no invented semantics.
func (p *M5) Handle(ctx context.Context, ev consumer.RawEvent) error {
	switch ev.Topic {
	case dkd.TopicCustodyPassportCustodyInitializedV1:
		var body struct {
			GPID string `json:"gpid"`
		}
		if err := json.Unmarshal(ev.Value, &body); err != nil || body.GPID == "" {
			p.m.Inc(MetricSkipped)
			p.log.Warn("custody event without parsable gpid; skipped (schema NEEDS-INFO)",
				"topic", ev.Topic, "event_id", ev.EventID)
			return nil
		}
		// dedup + delta commit atomically: a failed delta never strands the inbox row
		dup, err := p.st.ApplyPassportDeltaOnce(ctx, ev.EventID, body.GPID, 1)
		if err != nil {
			return err
		}
		if dup {
			p.m.Inc(MetricDeduped)
			return nil
		}
		p.m.Inc(MetricApplied)
	default:
		dup, err := p.st.InboxSeen(ctx, ev.EventID)
		if err != nil {
			return err
		}
		if dup {
			p.m.Inc(MetricDeduped)
			return nil
		}
		p.m.Inc(MetricSkipped)
	}
	return nil
}

// Park acknowledges a poison event after logging: the M5 projection is rebuildable by replay,
// so parking never blocks the partition (decision recorded in the BUILD LOG).
func (p *M5) Park(ev consumer.RawEvent, cause error) bool {
	p.m.Inc(MetricParked)
	p.log.Error("M5 projection event parked (projection is rebuildable by replay)",
		"topic", ev.Topic, "event_id", ev.EventID, "err", cause)
	return true
}
