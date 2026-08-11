// Package projection maps custody spine events onto the Neo4j graph. Every graph apply is an
// idempotent MERGE (keyed by ppid/eventHash), so no inbox table is needed: replays are no-ops.
// Park acks after logging — the graph is a disposable, replay-rebuildable index (R1).
package projection

import (
	"context"
	"encoding/json"

	"log/slog"

	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"

	"gitlab.com/final-year-project3354127/provenance-svc/internal/consumer"
	"gitlab.com/final-year-project3354127/provenance-svc/internal/graph"
)

const (
	MetricApplied = "provenance_events_applied_total"
	MetricSkipped = "provenance_events_skipped_total"
	MetricParked  = "provenance_events_parked_total"
)

type Metrics interface{ Inc(name string) }

type Handler struct {
	g   *graph.Client
	m   Metrics
	log *slog.Logger
	now func() int64
}

func New(g *graph.Client, m Metrics, log *slog.Logger, now func() int64) *Handler {
	return &Handler{g: g, m: m, log: log, now: now}
}

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

func (h *Handler) Handle(ctx context.Context, ev consumer.RawEvent) error {
	var fields map[string]any
	if err := json.Unmarshal(ev.Value, &fields); err != nil {
		h.m.Inc(MetricSkipped)
		h.log.Warn("unparsable custody event; skipped", "topic", ev.Topic, "event_id", ev.EventID)
		return nil
	}
	str := func(k string) string { s, _ := fields[k].(string); return s }
	i64 := func(k string) int64 {
		if f, ok := fields[k].(float64); ok {
			return int64(f)
		}
		return 0
	}
	// M2 review fix: use the event's OWN timestamp (the out-of-order guard depends on it)
	at := int64(0)
	for _, k := range []string{"initializedAt", "transferredAt", "splitAt", "mergedAt", "recalledAt", "signedAt"} {
		if v := i64(k); v > 0 {
			at = v
			break
		}
	}
	if at == 0 {
		at = h.now()
	}
	var err error
	switch ev.Topic {
	case dkd.TopicCustodyPassportCustodyInitializedV1:
		err = h.g.ApplyInitialized(ctx, fields, at)
	case dkd.TopicCustodyPassportCustodyTransferredV1:
		err = h.g.ApplyTransferred(ctx, fields, at)
	case dkd.TopicCustodyPassportCustodySplitV1:
		var children []graph.ChildAlloc
		if allocs, ok := fields["allocations"].([]any); ok {
			for _, a := range allocs {
				if m, ok := a.(map[string]any); ok {
					q, _ := m["quantity"].(float64)
					hs, _ := m["holder"].(string)
					rs, _ := m["holderRole"].(string)
					ps, _ := m["ppid"].(string)
					children = append(children, graph.ChildAlloc{PPID: ps, Holder: hs, Role: rs, Quantity: int64(q)})
				}
			}
		}
		err = h.g.ApplySplit(ctx, str("parentPpid"), str("gpid"), str("unit"), str("eventHash"), children, at)
	case dkd.TopicCustodyPassportCustodyMergedV1:
		var sources []string
		if sp, ok := fields["sourcePpids"].([]any); ok {
			for _, s := range sp {
				if v, ok := s.(string); ok {
					sources = append(sources, v)
				}
			}
		}
		err = h.g.ApplyMerged(ctx, sources, str("newPpid"), str("gpid"), str("toHolder"),
			str("toHolderRole"), str("unit"), str("eventHash"), i64("totalQuantity"), at)
	case dkd.TopicCustodyPassportProductRecalledV1:
		var ppids []string
		if pp, ok := fields["ppids"].([]any); ok {
			for _, p := range pp {
				if v, ok := p.(string); ok {
					ppids = append(ppids, v)
				}
			}
		}
		err = h.g.ApplyRecalled(ctx, ppids, str("recallId"), str("gpid"), str("reason"), at)
	case dkd.TopicCustodyPassportCustodialSignedV1:
		err = h.g.ApplySigned(ctx, str("ppid"), str("agentDid"), at)
	default:
		h.m.Inc(MetricSkipped)
		return nil
	}
	if err != nil {
		return err
	}
	h.m.Inc(MetricApplied)
	return nil
}

// Park (PRV-05): the ONLY failure source is a transient graph write, so we must NOT commit-and-skip
// (which silently drifted the projection). Return false → the offset is not committed and the record
// replays until the graph write succeeds (the projection is rebuildable; effectively-once holds via
// downstream idempotency). A permanent poison would surface via these repeated error logs for ops.
func (h *Handler) Park(ev consumer.RawEvent, cause error) bool {
	h.m.Inc(MetricParked)
	h.log.Error("provenance projection event NOT committed — will replay (no silent drop, PRV-05)",
		"topic", ev.Topic, "event_id", ev.EventID, "err", cause)
	return false
}
