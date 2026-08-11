// Package messaging wires Kafka — consumer(s) that mirror auth events
// into the profile DB, and an outbox relay that publishes profile events
// to Kafka. Consumer uses kafka-go ReaderConfig with autocommit; the
// `dokandar.user.created` upsert is idempotent (ON CONFLICT DO NOTHING),
// and the kyc mirror checks `WHERE kyc <> $2` before updating, so replays
// are no-ops.
package messaging

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"time"

	"github.com/segmentio/kafka-go"

	"github.com/dokandar/dokandar-profile/internal/domain/outbox"
	"github.com/dokandar/dokandar-profile/internal/domain/profile"
	"github.com/dokandar/dokandar-profile/internal/observability"
)

// ===========================================================================
//  Consumer — listens to:
//    dokandar.user.created   → upsert empty profile shell
//    dokandar.user.updated   → mirror phone/email (best-effort)
//    dokandar.kyc.submitted  → mirror kyc='submitted'
//    dokandar.kyc.approved   → mirror kyc='verified'
//    dokandar.kyc.rejected   → mirror kyc='rejected'
// ===========================================================================

type AuthEventConsumer struct {
	Brokers []string
	Topics  []string // every topic this consumer reads
	Group   string
	Store   *profile.Store
}

type userEvent struct {
	Event   string `json:"event"`
	UserID  string `json:"user_id"`
	Phone   string `json:"phone"`
	Role    string `json:"role"`
	Name    string `json:"name"`
	Email   string `json:"email,omitempty"`
	Lang    string `json:"lang,omitempty"`
	Created string `json:"created_at,omitempty"`
}

type kycEvent struct {
	Event           string `json:"event"`
	SubmissionID    string `json:"submission_id"`
	UserID          string `json:"user_id"`
	DecidedAt       string `json:"decided_at,omitempty"`
	RejectionReason string `json:"rejection_reason,omitempty"`
	SubmittedAt     string `json:"submitted_at,omitempty"`
}

// Run subscribes to all configured topics in a single consumer group, so
// partitions distribute across replicas. Returns when ctx is canceled.
func (c *AuthEventConsumer) Run(ctx context.Context) error {
	r := kafka.NewReader(kafka.ReaderConfig{
		Brokers:       c.Brokers,
		GroupTopics:   c.Topics,
		GroupID:       c.Group,
		StartOffset:   kafka.FirstOffset,
		MinBytes:      1,
		MaxBytes:      10 << 20,
		CommitInterval: 1 * time.Second,
		// Surface genuine consumer-group errors (join/sync/assignment failures) to
		// stderr→journald; the verbose per-poll Logger is intentionally omitted so
		// benign fetch timeouts don't drown real signal.
		ErrorLogger: kafka.LoggerFunc(func(msg string, a ...interface{}) {
			fmt.Fprintf(os.Stderr, "[kafka-go-ERR] "+msg+"\n", a...)
		}),
	})
	defer r.Close()

	slog.Info("kafka: consumer started",
		"name", "profile.kafka",
		"topics", c.Topics, "group", c.Group, "brokers", c.Brokers)

	for {
		m, err := r.ReadMessage(ctx)
		if err != nil {
			if errors.Is(err, context.Canceled) {
				return nil
			}
			slog.Warn("kafka: read failed", "name", "profile.kafka", "err", err.Error())
			time.Sleep(1 * time.Second)
			continue
		}
		c.handle(ctx, m)
	}
}

func (c *AuthEventConsumer) handle(ctx context.Context, m kafka.Message) {
	switch {
	case strings.HasSuffix(m.Topic, ".user.created"),
		strings.HasSuffix(m.Topic, ".user.updated"):
		var ev userEvent
		if err := json.Unmarshal(m.Value, &ev); err != nil {
			slog.Warn("kafka: user event unmarshal", "name", "profile.consumer", "offset", m.Offset, "err", err)
			return
		}
		if ev.UserID == "" {
			return
		}
		var emailPtr *string
		if ev.Email != "" {
			emailPtr = &ev.Email
		}
		if strings.HasSuffix(m.Topic, ".user.created") {
			var nameEnPtr *string
			if ev.Name != "" {
				nameEnPtr = &ev.Name
			}
			locale := "bn"
			if ev.Lang != "" {
				locale = ev.Lang
			}
			if err := c.Store.Upsert(ctx, ev.UserID, ev.Phone, emailPtr, nameEnPtr, locale); err != nil {
				slog.Warn("kafka: profile upsert", "name", "profile.consumer", "user_id", ev.UserID, "err", err)
				return
			}
			observability.ProfileShellsCreated.Inc()
			slog.Info("profile shell upserted", "name", "profile.consumer", "user_id", ev.UserID, "topic", m.Topic, "offset", m.Offset)
		} else {
			if err := c.Store.MirrorAuthUser(ctx, ev.UserID, ev.Phone, emailPtr); err != nil {
				slog.Warn("kafka: auth user mirror", "name", "profile.consumer", "user_id", ev.UserID, "err", err)
			}
		}

	case strings.HasSuffix(m.Topic, ".kyc.submitted"),
		strings.HasSuffix(m.Topic, ".kyc.approved"),
		strings.HasSuffix(m.Topic, ".kyc.rejected"):
		var ev kycEvent
		if err := json.Unmarshal(m.Value, &ev); err != nil {
			slog.Warn("kafka: kyc event unmarshal", "name", "profile.consumer", "offset", m.Offset, "err", err)
			return
		}
		if ev.UserID == "" {
			return
		}
		newKyc := ""
		switch {
		case strings.HasSuffix(m.Topic, ".kyc.submitted"):
			newKyc = "submitted"
		case strings.HasSuffix(m.Topic, ".kyc.approved"):
			newKyc = "verified"
		case strings.HasSuffix(m.Topic, ".kyc.rejected"):
			newKyc = "rejected"
		}
		changed, err := c.Store.MirrorKyc(ctx, ev.UserID, newKyc)
		if err != nil {
			slog.Warn("kafka: kyc mirror", "name", "profile.consumer", "user_id", ev.UserID, "err", err)
			return
		}
		if changed {
			observability.KycMirrorUpdates.WithLabelValues("?", newKyc).Inc()
		}
		slog.Info("kyc mirrored", "name", "profile.consumer", "user_id", ev.UserID, "to", newKyc, "topic", m.Topic, "changed", changed)
	}
}

// ===========================================================================
//  Outbox relay — reads pending outbox rows, writes them to Kafka, marks sent.
// ===========================================================================

type OutboxRelay struct {
	Brokers  []string
	Store    *outbox.Store
	Interval time.Duration
}

func (or *OutboxRelay) Run(ctx context.Context) error {
	writer := &kafka.Writer{
		Addr:         kafka.TCP(or.Brokers...),
		Balancer:     &kafka.Hash{},
		BatchTimeout: 200 * time.Millisecond,
		RequiredAcks: kafka.RequireAll,
		// Trigger broker-side auto-create on first produce; without this the
		// Writer never sends the auto-create flag and produce fails with
		// UNKNOWN_TOPIC_OR_PARTITION until the topic is provisioned elsewhere.
		AllowAutoTopicCreation: true,
	}
	defer writer.Close()

	tick := time.NewTicker(or.Interval)
	defer tick.Stop()

	slog.Info("outbox relay started", "name", "profile.outbox", "interval", or.Interval)

	for {
		select {
		case <-ctx.Done():
			return nil
		case <-tick.C:
			or.tick(ctx, writer)
		}
	}
}

func (or *OutboxRelay) tick(ctx context.Context, w *kafka.Writer) {
	rows, err := or.Store.LoadPending(ctx, 50)
	if err != nil {
		slog.Warn("outbox: load pending", "name", "profile.outbox", "err", err)
		return
	}
	for _, r := range rows {
		err := w.WriteMessages(ctx, kafka.Message{
			Topic: r.Topic,
			Key:   []byte(r.AggregateID),
			Value: r.Payload,
		})
		if err != nil {
			slog.Warn("outbox: kafka write", "name", "profile.outbox", "topic", r.Topic, "id", r.ID, "err", err)
			continue
		}
		if err := or.Store.MarkSent(ctx, r.ID); err != nil {
			slog.Warn("outbox: mark sent", "name", "profile.outbox", "id", r.ID, "err", err)
			continue
		}
		observability.OutboxRelayed.Inc()
	}
	if n, err := or.Store.CountPending(ctx); err == nil {
		observability.OutboxPending.Set(float64(n))
	}
}
