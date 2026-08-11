// Package scheduler — the ONLY producer of platform.scheduler.* (frozen registry,
// producer 13). Drivers are canon-verbatim (DM Scheduler Event Catalog):
//   - CoolingOffExpired at each escrow's coolingOffExpiresAt (Saga 3)
//   - EscrowExpired at createdAt + ESCROW_ABANDON_TTL (7d default, m-EscExp errata: createdAt)
//   - NILRollupRefresh every 60s per GPID (the GPID set source is canon NEEDS-INFO — env-fed)
//
// Timer state is learned from finance.escrow.* events. The frozen registry lists NO topic
// with consumer 13 for finance — yet Saga 3 explicitly requires the scheduler to know
// esc/createdAt/coolingOffExpiresAt. Registry gap logged for an additive ADR; the DM saga
// wins (ADR-016 spirit). R2 stays intact: events only, never Finance's store.
package scheduler

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"log/slog"

	"github.com/jackc/pgx/v5"
	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"

	"gitlab.com/final-year-project3354127/platform-services/internal/consumer"
	"gitlab.com/final-year-project3354127/platform-services/internal/store"
)

const (
	MetricFired     = "scheduler_events_fired_total"
	MetricProcessed = "scheduler_spine_processed_total"
	platformContext = 13
)

type Metrics interface{ Inc(name string) }

func Topics() []string {
	return []string{
		dkd.TopicFinanceEscrowEscrowCreatedV1,
		dkd.TopicFinanceEscrowEscrowReleasedV1,
		dkd.TopicFinanceEscrowSettlementHoldReleasedV1,
		dkd.TopicFinanceEscrowEscrowReversedV1,
	}
}

type Scheduler struct {
	st       *store.Store
	log      *slog.Logger
	m        Metrics
	now      func() int64
	ttlMs    int64
	nilGpids []string
}

func New(st *store.Store, log *slog.Logger, m Metrics, now func() int64,
	escrowAbandonMs int64, nilGpids []string) *Scheduler {
	return &Scheduler{st: st, log: log, m: m, now: now, ttlMs: escrowAbandonMs,
		nilGpids: nilGpids}
}

// ---- spine handler: escrow lifecycle → local timers ----

func (s *Scheduler) Handle(ctx context.Context, ev consumer.RawEvent) error {
	var p struct {
		Esc                 string `json:"esc"`
		ReferenceID         string `json:"referenceId"`
		ReferenceType       string `json:"referenceType"`
		CoolingOffExpiresAt *int64 `json:"coolingOffExpiresAt"`
		OccurredAt          int64  `json:"occurredAt"`
	}
	if err := json.Unmarshal(ev.Value, &p); err != nil || p.Esc == "" {
		s.log.Info("skip malformed escrow event", "topic", ev.Topic)
		return nil
	}
	now := s.now()
	createdAt := p.OccurredAt
	if createdAt == 0 {
		createdAt = now
	}
	done, err := s.st.ConsumeOnceIn(ctx, "scheduler_inbox", ev.EventID, ev.Topic, now,
		func(tx pgx.Tx) error {
			switch ev.Topic {
			case dkd.TopicFinanceEscrowEscrowCreatedV1:
				return s.st.UpsertTimerTx(ctx, tx, store.Timer{
					Esc: p.Esc, ReferenceID: p.ReferenceID, ReferenceType: p.ReferenceType,
					CreatedAt: createdAt, State: "ACTIVE"}, now)
			case dkd.TopicFinanceEscrowEscrowReleasedV1:
				return s.st.UpsertTimerTx(ctx, tx, store.Timer{
					Esc: p.Esc, ReferenceID: p.ReferenceID, ReferenceType: p.ReferenceType,
					CreatedAt: createdAt, CoolingOffExpiresAt: p.CoolingOffExpiresAt,
					State: "SETTLEMENT_HELD"}, now)
			default: // SettlementHoldReleased | EscrowReversed — nothing left to time
				return s.st.CloseTimerTx(ctx, tx, p.Esc, now)
			}
		})
	if done {
		s.m.Inc(MetricProcessed)
	}
	return err
}

// Park (PLAT-06): called only after the consumer's bounded inline retries are exhausted. Quarantine
// the poison record to the DLQ and advance (return true) so one bad event no longer blocks the
// partition forever; a DLQ-insert failure keeps the record (return false — never a silent drop).
func (s *Scheduler) Park(ev consumer.RawEvent, cause error) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if perr := s.st.ParkDLQ(ctx, ev.EventID, ev.Topic, ev.Key, ev.Value, cause.Error(), s.now()); perr != nil {
		s.log.Error("DLQ park FAILED — keep replaying (never drop)", "event_id", ev.EventID, "err", perr)
		return false
	}
	s.log.Error("scheduler poison event PARKED to DLQ after bounded retries — partition advancing",
		"topic", ev.Topic, "event_id", ev.EventID, "err", cause)
	return true
}

// ---- tick loop ----

func (s *Scheduler) RunTicks(ctx context.Context, tick, nilTick time.Duration) {
	t := time.NewTicker(tick)
	n := time.NewTicker(nilTick)
	defer t.Stop()
	defer n.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := s.FireDue(ctx); err != nil {
				s.log.Error("fire-due failed", "err", err)
			}
		case <-n.C:
			if err := s.FireNILRefresh(ctx); err != nil {
				s.log.Error("nil-refresh failed", "err", err)
			}
		}
	}
}

// FireDue emits CoolingOffExpired and EscrowExpired for due timers, exactly once per
// canon idempotencyKey (scheduler_fired PK + outbox row commit atomically).
func (s *Scheduler) FireDue(ctx context.Context) error {
	now := s.now()
	held, err := s.st.DueCoolingOff(ctx, now, 100)
	if err != nil {
		return err
	}
	for _, t := range held {
		expiresAt := int64(0)
		if t.CoolingOffExpiresAt != nil {
			expiresAt = *t.CoolingOffExpiresAt
		}
		idemKey := fmt.Sprintf("ESC:%s:cooling-off:%d", t.Esc, expiresAt)
		ev, err := s.event(dkd.TopicPlatformSchedulerCoolingOffExpiredV1, t.Esc, map[string]any{
			"esc": t.Esc, "referenceId": t.ReferenceID, "referenceType": t.ReferenceType,
			"coolingOffExpiresAt": expiresAt, "triggeredAt": now, "idempotencyKey": idemKey,
		}, now)
		if err != nil {
			return err
		}
		fired, err := s.st.FireOnce(ctx, idemKey, ev, now)
		if err != nil {
			return err
		}
		if fired {
			s.m.Inc(MetricFired)
			s.log.Info("CoolingOffExpired fired", "esc", t.Esc)
		}
	}
	abandoned, err := s.st.DueAbandoned(ctx, now-s.ttlMs, 100)
	if err != nil {
		return err
	}
	for _, t := range abandoned {
		// firedKey (stable, per-esc) prevents a second local fire; the payload idemKey
		// carries triggeredAt per the canon shape and is the hint finance's inbox dedups on.
		firedKey := fmt.Sprintf("ESC:%s:expired", t.Esc)
		idemKey := fmt.Sprintf("ESC:%s:expired:%d", t.Esc, now)
		ev, err := s.event(dkd.TopicPlatformSchedulerEscrowExpiredV1, t.Esc, map[string]any{
			"esc": t.Esc, "referenceId": t.ReferenceID, "referenceType": t.ReferenceType,
			"createdAt": t.CreatedAt, "triggeredAt": now, "idempotencyKey": idemKey,
		}, now)
		if err != nil {
			return err
		}
		fired, err := s.st.FireOnce(ctx, firedKey, ev, now)
		if err != nil {
			return err
		}
		if fired {
			s.m.Inc(MetricFired)
			s.log.Info("EscrowExpired fired", "esc", t.Esc)
		}
	}
	return nil
}

// FireNILRefresh emits one NILRollupRefresh per configured GPID (canon: every 60s, key GPID).
func (s *Scheduler) FireNILRefresh(ctx context.Context) error {
	now := s.now()
	for _, gpid := range s.nilGpids {
		idemKey := fmt.Sprintf("NIL:%s:refresh:%d", gpid, now)
		ev, err := s.event(dkd.TopicPlatformSchedulerNILRollupRefreshV1, gpid, map[string]any{
			"gpid": gpid, "triggeredAt": now, "idempotencyKey": idemKey,
		}, now)
		if err != nil {
			return err
		}
		if _, err := s.st.FireOnce(ctx, idemKey, ev, now); err != nil {
			return err
		}
	}
	return nil
}

// event builds a Published-Language payload with the producer-13 guard (R6).
func (s *Scheduler) event(topic, key string, fields map[string]any, now int64) (store.OutboxRow, error) {
	meta, ok := dkd.TopicMetaFor(topic)
	if !ok || meta.Producer != platformContext {
		return store.OutboxRow{}, fmt.Errorf("R6 violation: platform may not produce %s", topic)
	}
	eventID := NewUUID7()
	payload := map[string]any{"eventId": eventID, "occurredAt": now}
	for k, v := range fields {
		payload[k] = v
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return store.OutboxRow{}, err
	}
	return store.OutboxRow{EventID: eventID, Topic: topic, Key: key, Payload: raw}, nil
}
