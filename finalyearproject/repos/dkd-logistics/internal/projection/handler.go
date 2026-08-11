// Package projection consumes the b2c order topics that drive the shipment sagas
// (DM Saga 1: OrderPlaced -> CreateShipment; Saga 2: OrderCancelled -> CancelShipment).
// Inbox dedup commits atomically with effects; park returns false (order-critical replays).
package projection

import (
	"context"
	"encoding/json"
	"time"

	"log/slog"

	"github.com/jackc/pgx/v5"
	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"

	"gitlab.com/final-year-project3354127/logistics-svc/internal/clients"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/consumer"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/events"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/obs"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/store"
)

const (
	MetricProcessed = "logistics_spine_processed_total"
	MetricSkipped   = "logistics_spine_skipped_total"
	MetricParked    = "logistics_spine_dlq_parked_total"
)

func Topics() []string {
	return []string{
		dkd.TopicB2cOrderOrderPlacedV1,
		dkd.TopicB2cOrderOrderCancelledV1,
		dkd.TopicB2cOrderOrderProcessingStartedV1,
	}
}

type Handler struct {
	st  *store.Store
	cl  *clients.HTTP
	m   *obs.Metrics
	log *slog.Logger
	now func() int64
}

func New(st *store.Store, cl *clients.HTTP, m *obs.Metrics, log *slog.Logger, now func() int64) *Handler {
	return &Handler{st: st, cl: cl, m: m, log: log, now: now}
}

// Park (LOG-03): called only AFTER the consumer's bounded inline retries are exhausted. Quarantine the
// poison record to the DLQ and return true so the offset advances (partition no longer blocks forever).
// If the DLQ insert itself fails, return false → the record is not committed and replays (never dropped).
func (h *Handler) Park(ev consumer.RawEvent, err error) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if perr := h.st.ParkDLQ(ctx, ev.EventID, ev.Topic, ev.Key, ev.Value, err.Error(), h.now()); perr != nil {
		h.log.Error("DLQ park FAILED — keep replaying (never drop)", "event_id", ev.EventID, "err", perr)
		return false
	}
	h.m.Inc(MetricParked)
	h.log.Error("logistics poison event PARKED to DLQ after bounded retries — partition advancing",
		"topic", ev.Topic, "event_id", ev.EventID, "err", err)
	return true
}

func (h *Handler) Handle(ctx context.Context, ev consumer.RawEvent) error {
	var p map[string]any
	if err := json.Unmarshal(ev.Value, &p); err != nil {
		h.log.Warn("unparseable payload — ack+skip", "topic", ev.Topic)
		h.m.Inc(MetricSkipped)
		return nil
	}
	now := h.now()
	switch ev.Topic {
	case dkd.TopicB2cOrderOrderPlacedV1:
		ord := str(p, "ord", "orderId")
		if ord == "" {
			h.m.Inc(MetricSkipped)
			return nil
		}
		// Delivery address via the B2C internal seam — the only reader (FR-MKT-004).
		var delivery json.RawMessage
		if h.cl.Enabled() {
			io, err := h.cl.InternalOrder(ctx, ord)
			if err != nil {
				return err // retryable: B2C should know its own order
			}
			delivery = io.DeliveryAddress
		}
		done, err := h.st.ConsumeOnce(ctx, ev.EventID, ev.Topic, now, func(tx pgx.Tx) error {
			_, _, cErr := h.st.CreateShipmentTx(ctx, tx, ord, "ORDER", nil, delivery,
				func(shp string) store.OutboxRow { return events.ShipmentCreated(shp, ord, "ORDER", now) }, now)
			return cErr
		})
		if err != nil {
			return err
		}
		if done {
			h.m.Inc(MetricProcessed)
		}
		return nil
	case dkd.TopicB2cOrderOrderCancelledV1:
		ord := str(p, "ord", "orderId")
		if ord == "" {
			h.m.Inc(MetricSkipped)
			return nil
		}
		reason := str(p, "reason")
		if reason == "" {
			reason = "ORDER_CANCELLED"
		}
		done, err := h.st.ConsumeOnce(ctx, ev.EventID, ev.Topic, now, func(tx pgx.Tx) error {
			_, cErr := h.st.CancelByReferenceTx(ctx, tx, ord, "ORDER", reason, func(shp string) store.OutboxRow {
				return events.ShipmentCancelled(shp, ord, "ORDER", reason, now)
			}, now)
			return cErr
		})
		if done { // inbox-dedup replays must not count as processed (reviewer M-5)
			h.m.Inc(MetricProcessed)
		}
		return err
	default:
		// OrderProcessingStarted: registry lists #9 as consumer, behavior unstated (NEEDS-INFO).
		h.m.Inc(MetricSkipped)
		return nil
	}
}

func str(p map[string]any, names ...string) string {
	for _, n := range names {
		if v, ok := p[n].(string); ok && v != "" {
			return v
		}
	}
	return ""
}
