// Package consumer is the platform's FIRST real Kafka client (franz-go). As the R6 OHS audit sink
// it CONSUMES every spine topic and never produces. It is the de-facto reference implementation for
// every future DOKANDAR Kafka consumer.
package consumer

import (
	"context"
	"encoding/json"
	"fmt"

	"log/slog"

	"github.com/twmb/franz-go/pkg/kgo"

	"gitlab.com/final-year-project3354127/audit-log-svc/internal/audit"
)

// Handler persists a consumed event. Returning an error asks the caller to park the record.
type Handler func(ctx context.Context, e audit.RawEvent) error

// ParkFunc dead-letters a poison record and reports whether the park succeeded. A record is only
// considered safely handled (and its offset committable) once it is either persisted or parked.
type ParkFunc func(e audit.RawEvent, cause error) bool

// Config configures the consumer. Note the DELIBERATE ABSENCE of any auto-create option: per
// CORRECTION 2 the sink MUST NOT create topics (topic geometry is owned by the emitting contexts
// under R6) and MUST NOT rely on broker auto-create. franz-go does not create topics on subscribe;
// it tolerates a missing topic and attaches to it on the next metadata refresh once its owner
// creates it.
type Config struct {
	Brokers []string
	Group   string
	Topics  []string
}

// Consumer wraps a franz-go client bound to a stable consumer group over a fixed topic set.
type Consumer struct {
	client *kgo.Client
	log    *slog.Logger
	handle Handler
	park   ParkFunc
}

// New builds the consumer. It validates config and constructs the client but does NOT connect
// (franz-go connects lazily on first poll/ping).
func New(cfg Config, log *slog.Logger, handle Handler, park ParkFunc) (*Consumer, error) {
	if len(cfg.Brokers) == 0 {
		return nil, fmt.Errorf("consumer: no brokers configured")
	}
	if len(cfg.Topics) == 0 {
		return nil, fmt.Errorf("consumer: no topics configured")
	}
	if cfg.Group == "" {
		return nil, fmt.Errorf("consumer: no group configured")
	}
	if handle == nil {
		return nil, fmt.Errorf("consumer: nil handler")
	}
	if park == nil {
		return nil, fmt.Errorf("consumer: nil park func")
	}
	cl, err := kgo.NewClient(
		kgo.SeedBrokers(cfg.Brokers...),
		kgo.ConsumerGroup(cfg.Group),
		kgo.ConsumeTopics(cfg.Topics...),
		kgo.DisableAutoCommit(),                           // commit AFTER persistence (effectively-once + inbox dedup)
		kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()), // an audit sink must not miss history
		kgo.ClientID("audit-log-svc"),
		// kgo.AllowAutoTopicCreation() is intentionally OMITTED — the sink never creates topics (R6).
	)
	if err != nil {
		return nil, fmt.Errorf("kgo client: %w", err)
	}
	return &Consumer{client: cl, log: log, handle: handle, park: park}, nil
}

// Ping verifies broker connectivity (used to gate /ready green only once Kafka is reachable).
func (c *Consumer) Ping(ctx context.Context) error { return c.client.Ping(ctx) }

// Run consumes until ctx is cancelled or the client is closed. Offsets are committed only for the
// contiguous prefix of records that were successfully persisted or parked; on a hard failure (both
// persist AND park fail) processing stops and the remaining offsets are left uncommitted so the
// records replay — a record is NEVER silently dropped, and replays are de-duplicated by the inbox.
func (c *Consumer) Run(ctx context.Context) {
	for {
		fetches := c.client.PollFetches(ctx)
		if fetches.IsClientClosed() {
			return
		}
		if ctx.Err() != nil {
			return
		}
		fetches.EachError(func(t string, p int32, err error) {
			c.log.Warn("kafka fetch error", "topic", t, "partition", p, "err", err)
		})
		var committable []*kgo.Record
		safe := true
		fetches.EachRecord(func(r *kgo.Record) {
			if !safe {
				return // preserve order: stop advancing past the first hard failure
			}
			e := toRawEvent(r)
			if err := c.handle(ctx, e); err != nil {
				if !c.park(e, err) {
					c.log.Error("handle AND park both failed; halting commit so the record replays (never dropped)",
						"topic", e.Topic, "event_id", e.EventID, "err", err)
					safe = false
					return
				}
				c.log.Warn("record parked to DLQ (park-and-freeze)", "topic", e.Topic, "event_id", e.EventID, "err", err)
			}
			committable = append(committable, r)
		})
		if len(committable) > 0 {
			if err := c.client.CommitRecords(ctx, committable...); err != nil {
				c.log.Warn("offset commit failed (will replay; inbox dedup makes this safe)", "err", err)
			}
		}
	}
}

// Close shuts the client down (leaves the group cleanly).
func (c *Consumer) Close() { c.client.Close() }

// envelope is the minimal subset of the spine event envelope needed to resolve the dedup key.
type envelope struct {
	EventIDCamel string `json:"eventId"`
	EventIDSnake string `json:"event_id"`
}

// toRawEvent maps a Kafka record to a RawEvent, resolving the dedup event_id in priority order:
// header "event_id" → header "eventId" → payload "eventId" → payload "event_id" → synthesized
// topic/partition/offset (guarantees a stable non-empty key even for malformed producers).
func toRawEvent(r *kgo.Record) audit.RawEvent {
	eid := headerValue(r, "event_id")
	if eid == "" {
		eid = headerValue(r, "eventId")
	}
	if eid == "" {
		var env envelope
		if json.Unmarshal(r.Value, &env) == nil {
			switch {
			case env.EventIDCamel != "":
				eid = env.EventIDCamel
			case env.EventIDSnake != "":
				eid = env.EventIDSnake
			}
		}
	}
	if eid == "" {
		eid = fmt.Sprintf("%s/%d/%d", r.Topic, r.Partition, r.Offset)
	}
	return audit.RawEvent{
		Topic:     r.Topic,
		Key:       string(r.Key),
		EventID:   eid,
		Partition: r.Partition,
		Offset:    r.Offset,
		Value:     r.Value,
	}
}

func headerValue(r *kgo.Record, key string) string {
	for _, h := range r.Headers {
		if h.Key == key {
			return string(h.Value)
		}
	}
	return ""
}
