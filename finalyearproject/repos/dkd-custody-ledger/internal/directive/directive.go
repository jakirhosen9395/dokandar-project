// Package directive consumes government.oversight.RecallDirectiveIssued.v1 (R5: government
// DIRECTS, custody WRITES) and reacts by issuing the authoritative ProductRecalled custody
// events — one per GPID with ACTIVE passports. Custody-critical poison is NEVER dropped:
// Park returns false so the partition replays until the fault is fixed.
package directive

import (
	"context"
	"encoding/json"

	"log/slog"

	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"

	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/consumer"
	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/custody"
	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/store"
)

const (
	MetricDirectives = "custody_recall_directives_total"
	MetricDeduped    = "custody_directives_deduped_total"
	MetricRecalled   = "custody_recalled_passports_total"
	MetricSkipped    = "custody_directives_skipped_total"
)

type Store interface {
	InboxSeen(ctx context.Context, eventID string) (bool, error)
	ActiveByGPID(ctx context.Context, gpid string, limit int) ([]*custody.Passport, error)
	Append(ctx context.Context, ev custody.Event, occurredAtMs int64, affected []store.Affected) error
}

type Metrics interface{ Inc(name string) }

type Handler struct {
	st  Store
	m   Metrics
	log *slog.Logger
	now func() int64
}

func New(st Store, m Metrics, log *slog.Logger, now func() int64) *Handler {
	return &Handler{st: st, m: m, log: log, now: now}
}

func Topics() []string {
	return []string{dkd.TopicGovernmentOversightRecallDirectiveIssuedV1}
}

type directivePayload struct {
	RecallID string   `json:"recallId"`
	GPIDs    []string `json:"gpids"`
	Reason   string   `json:"reason"`
	IssuedBy string   `json:"issuedBy"`
}

// Handle is idempotent WITHOUT a pre-loop inbox short-circuit (C1 review fix): recall only
// targets ACTIVE passports, so a replay after a partial multi-GPID failure naturally no-ops
// the already-recalled GPIDs and completes the remainder. The inbox is marked only AFTER the
// whole directive succeeds (bookkeeping/metrics), never before.
func (h *Handler) Handle(ctx context.Context, ev consumer.RawEvent) error {
	var d directivePayload
	if err := json.Unmarshal(ev.Value, &d); err != nil || d.RecallID == "" || len(d.GPIDs) == 0 {
		if _, ierr := h.st.InboxSeen(ctx, ev.EventID); ierr != nil {
			return ierr
		}
		h.m.Inc(MetricSkipped)
		h.log.Warn("unparsable recall directive; skipped (schema NEEDS-INFO)",
			"event_id", ev.EventID, "err", err)
		return nil
	}
	for _, gpid := range d.GPIDs {
		targets, err := h.st.ActiveByGPID(ctx, gpid, 0)
		if err != nil {
			return err
		}
		if len(targets) == 0 {
			h.log.Info("recall directive: no active passports for gpid", "gpid", gpid, "recall_id", d.RecallID)
			continue
		}
		prevHeads := make([]string, len(targets))
		for i, t := range targets {
			prevHeads[i] = t.HeadHash
		}
		rev, err := custody.RecallProducts(targets, d.RecallID, d.Reason, d.IssuedBy, h.now())
		if err != nil {
			return err
		}
		affected := make([]store.Affected, len(targets))
		for i, t := range targets {
			affected[i] = store.Affected{Head: t, IsNew: false, RowPrevHash: prevHeads[i]}
		}
		if err := h.st.Append(ctx, rev, h.now(), affected); err != nil {
			return err
		}
		for range targets {
			h.m.Inc(MetricRecalled)
		}
	}
	// mark processed only after EVERY GPID is handled; dup here just means a clean redelivery
	dup, err := h.st.InboxSeen(ctx, ev.EventID)
	if err != nil {
		return err
	}
	if dup {
		h.m.Inc(MetricDeduped)
	} else {
		h.m.Inc(MetricDirectives)
	}
	return nil
}

// Park refuses to acknowledge: recall directives are custody-critical and must replay,
// never be dropped (the partition stalls until the fault is repaired — by design).
func (h *Handler) Park(ev consumer.RawEvent, cause error) bool {
	h.log.Error("RECALL DIRECTIVE FAILED — refusing to drop; partition will replay",
		"event_id", ev.EventID, "err", cause)
	return false
}
