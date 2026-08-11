// Package projection maps custody spine events onto strong-local stock records (R1 read-side).
// Payload field names follow the custody producer we operate (formal schemas NEEDS-INFO).
// Park acks after logging: the projection is fully rebuildable by replaying custody topics.
package projection

import (
	"context"
	"encoding/json"

	"log/slog"

	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"

	"gitlab.com/final-year-project3354127/inventory-svc/internal/consumer"
	"gitlab.com/final-year-project3354127/inventory-svc/internal/store"
)

const (
	MetricApplied = "inventory_events_applied_total"
	MetricDeduped = "inventory_events_deduped_total"
	MetricSkipped = "inventory_events_skipped_total"
	MetricParked  = "inventory_events_parked_total"
)

type Store interface {
	SeenOnce(ctx context.Context, eventID string) (bool, error)
	InitLotOnce(ctx context.Context, eventID, eventHash string, lot store.Lot, at int64) (bool, error)
	TransferOnce(ctx context.Context, eventID, eventHash, ppid, toHolder string, at int64) (bool, error)
	SplitOnce(ctx context.Context, eventID, eventHash, parentPpid string, children []store.Lot, at int64) (bool, error)
	MergeOnce(ctx context.Context, eventID, eventHash string, sourcePpids []string, newLot store.Lot, at int64) (bool, error)
	QuarantineOnce(ctx context.Context, eventID, eventHash string, ppids []string, at int64) (bool, error)
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
	return []string{
		dkd.TopicCustodyPassportCustodyInitializedV1,
		dkd.TopicCustodyPassportCustodyTransferredV1,
		dkd.TopicCustodyPassportCustodySplitV1,
		dkd.TopicCustodyPassportCustodyMergedV1,
		dkd.TopicCustodyPassportProductRecalledV1,
		dkd.TopicCatalogProductProductDeprecatedV1,
		dkd.TopicPlatformSchedulerNILRollupRefreshV1,
	}
}

func (h *Handler) count(dup bool, applied string) {
	if dup {
		h.m.Inc(MetricDeduped)
	} else {
		h.m.Inc(applied)
	}
}

func (h *Handler) Handle(ctx context.Context, ev consumer.RawEvent) error {
	at := h.now()
	switch ev.Topic {
	case dkd.TopicCustodyPassportCustodyInitializedV1:
		var raw struct {
			Ppid      string `json:"ppid"`
			Gpid      string `json:"gpid"`
			Holder    string `json:"holder"`
			EventHash string `json:"eventHash"`
			Unit     string `json:"unit"`
			Quantity int64  `json:"quantity"`
		}
		if err := json.Unmarshal(ev.Value, &raw); err != nil || raw.Ppid == "" {
			return h.skip(ctx, ev)
		}
		dup, err := h.st.InitLotOnce(ctx, ev.EventID, raw.EventHash, store.Lot{
			PPID: raw.Ppid, GPID: raw.Gpid, Holder: raw.Holder, Quantity: raw.Quantity, Unit: raw.Unit,
		}, at)
		if err != nil {
			return err
		}
		h.count(dup, MetricApplied)
	case dkd.TopicCustodyPassportCustodyTransferredV1:
		var raw struct {
			Ppid      string `json:"ppid"`
			ToHolder  string `json:"toHolder"`
			EventHash string `json:"eventHash"`
		}
		if err := json.Unmarshal(ev.Value, &raw); err != nil || raw.Ppid == "" || raw.ToHolder == "" {
			return h.skip(ctx, ev)
		}
		dup, err := h.st.TransferOnce(ctx, ev.EventID, raw.EventHash, raw.Ppid, raw.ToHolder, at)
		if err != nil {
			return err
		}
		h.count(dup, MetricApplied)
	case dkd.TopicCustodyPassportCustodySplitV1:
		var raw struct {
			EventHash   string `json:"eventHash"`
			ParentPpid  string `json:"parentPpid"`
			Gpid        string `json:"gpid"`
			Unit        string `json:"unit"`
			Allocations []struct {
				Ppid     string `json:"ppid"`
				Holder   string `json:"holder"`
				Quantity int64  `json:"quantity"`
			} `json:"allocations"`
		}
		if err := json.Unmarshal(ev.Value, &raw); err != nil || raw.ParentPpid == "" {
			return h.skip(ctx, ev)
		}
		children := make([]store.Lot, 0, len(raw.Allocations))
		for _, a := range raw.Allocations {
			children = append(children, store.Lot{PPID: a.Ppid, GPID: raw.Gpid, Holder: a.Holder,
				Quantity: a.Quantity, Unit: raw.Unit})
		}
		dup, err := h.st.SplitOnce(ctx, ev.EventID, raw.EventHash, raw.ParentPpid, children, at)
		if err != nil {
			return err
		}
		h.count(dup, MetricApplied)
	case dkd.TopicCustodyPassportCustodyMergedV1:
		var raw struct {
			EventHash     string   `json:"eventHash"`
			SourcePpids   []string `json:"sourcePpids"`
			NewPpid       string   `json:"newPpid"`
			Gpid          string   `json:"gpid"`
			ToHolder      string   `json:"toHolder"`
			Unit          string   `json:"unit"`
			TotalQuantity int64    `json:"totalQuantity"`
		}
		if err := json.Unmarshal(ev.Value, &raw); err != nil || raw.NewPpid == "" {
			return h.skip(ctx, ev)
		}
		dup, err := h.st.MergeOnce(ctx, ev.EventID, raw.EventHash, raw.SourcePpids, store.Lot{
			PPID: raw.NewPpid, GPID: raw.Gpid, Holder: raw.ToHolder,
			Quantity: raw.TotalQuantity, Unit: raw.Unit,
		}, at)
		if err != nil {
			return err
		}
		h.count(dup, MetricApplied)
	case dkd.TopicCustodyPassportProductRecalledV1:
		var raw struct {
			Ppids     []string `json:"ppids"`
			EventHash string   `json:"eventHash"`
		}
		if err := json.Unmarshal(ev.Value, &raw); err != nil || len(raw.Ppids) == 0 {
			return h.skip(ctx, ev)
		}
		dup, err := h.st.QuarantineOnce(ctx, ev.EventID, raw.EventHash, raw.Ppids, at)
		if err != nil {
			return err
		}
		h.count(dup, MetricApplied)
	default:
		// ProductDeprecated (stock effect NEEDS-INFO) and NILRollupRefresh (rollup is
		// computed on read, fresher than the <=60s SLO) are acknowledged extension points.
		return h.skip(ctx, ev)
	}
	return nil
}

func (h *Handler) skip(ctx context.Context, ev consumer.RawEvent) error {
	dup, err := h.st.SeenOnce(ctx, ev.EventID)
	if err != nil {
		return err
	}
	if dup {
		h.m.Inc(MetricDeduped)
	} else {
		h.m.Inc(MetricSkipped)
	}
	return nil
}

// Park acknowledges after logging: the stock projection is rebuildable by replay.
func (h *Handler) Park(ev consumer.RawEvent, cause error) bool {
	h.m.Inc(MetricParked)
	h.log.Error("inventory projection event parked (rebuildable by replay)",
		"topic", ev.Topic, "event_id", ev.EventID, "err", cause)
	return true
}
