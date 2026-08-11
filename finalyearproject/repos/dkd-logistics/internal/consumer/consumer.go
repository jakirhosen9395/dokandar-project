// Package consumer is custody-ledger-svc's spine consumer (government recall directives).
// Same discipline as the platform reference consumer (audit-log-svc): manual commits only
// after successful handling, no topic auto-creation (CORRECTION 2), park-or-replay.
package consumer

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"log/slog"

	"github.com/twmb/franz-go/pkg/kgo"
)

const (
	// LOG-03: a poison record is retried INLINE up to maxHandleAttempts (franz-go does not re-deliver
	// an uncommitted record within a session), then parked to the DLQ so the partition advances.
	maxHandleAttempts  = 8
	handleRetryBackoff = 1500 * time.Millisecond
)

type RawEvent struct {
	Topic     string
	Key       string
	EventID   string
	Partition int32
	Offset    int64
	Value     []byte
}

type Handler func(context.Context, RawEvent) error

// ParkFunc must return true only when the failed event is safely parked; false means the
// offset is NOT committed and the record replays (never silently dropped).
type ParkFunc func(RawEvent, error) bool

type Config struct {
	Brokers []string
	Group   string
	Topics  []string
}

type Consumer struct {
	cl     *kgo.Client
	log    *slog.Logger
	handle Handler
	park   ParkFunc
}

func New(cfg Config, log *slog.Logger, handle Handler, park ParkFunc) (*Consumer, error) {
	if len(cfg.Brokers) == 0 {
		return nil, fmt.Errorf("consumer: brokers required")
	}
	if len(cfg.Topics) == 0 {
		return nil, fmt.Errorf("consumer: topics required")
	}
	if cfg.Group == "" {
		return nil, fmt.Errorf("consumer: group required")
	}
	if handle == nil {
		return nil, fmt.Errorf("consumer: handler required")
	}
	if park == nil {
		return nil, fmt.Errorf("consumer: park func required")
	}
	cl, err := kgo.NewClient(
		kgo.SeedBrokers(cfg.Brokers...),
		kgo.ConsumerGroup(cfg.Group),
		kgo.ConsumeTopics(cfg.Topics...),
		kgo.DisableAutoCommit(),
		kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()),
	)
	if err != nil {
		return nil, fmt.Errorf("consumer: kafka client: %w", err)
	}
	return &Consumer{cl: cl, log: log, handle: handle, park: park}, nil
}

func (c *Consumer) Ping(ctx context.Context) error { return c.cl.Ping(ctx) }
func (c *Consumer) Close()                         { c.cl.Close() }

// Run polls until ctx is done, committing only the successfully handled (or safely parked)
// prefix of each partition batch.
func (c *Consumer) Run(ctx context.Context) {
	for {
		if ctx.Err() != nil {
			return
		}
		fetches := c.cl.PollFetches(ctx)
		if fetches.IsClientClosed() || ctx.Err() != nil {
			return
		}
		fetches.EachError(func(t string, p int32, err error) {
			c.log.Warn("fetch error", "topic", t, "partition", p, "err", err)
		})
		var safe []*kgo.Record
		// a poison record stops advancement ONLY for its own partition; healthy partitions
		// in the same fetch keep committing (review MEDIUM fix)
		stopped := map[string]bool{}
		fetches.EachRecord(func(rec *kgo.Record) {
			pk := fmt.Sprintf("%s/%d", rec.Topic, rec.Partition)
			if stopped[pk] {
				return
			}
			ev := toRawEvent(rec)
			// LOG-03: bounded INLINE retry (transient failures recover), then park to the DLQ.
			var herr error
			for attempt := 1; attempt <= maxHandleAttempts; attempt++ {
				if herr = c.handle(ctx, ev); herr == nil {
					break
				}
				if attempt < maxHandleAttempts {
					c.log.Warn("handle failed — inline retry",
						"topic", ev.Topic, "event_id", ev.EventID, "attempt", attempt, "err", herr)
					select {
					case <-ctx.Done():
						return
					case <-time.After(handleRetryBackoff):
					}
				}
			}
			if herr != nil {
				// retries exhausted → park to DLQ; park returns true to advance, false to halt+replay
				if !c.park(ev, herr) {
					c.log.Error("handle+park failed; partition not advancing (will replay)",
						"topic", ev.Topic, "partition", ev.Partition, "event_id", ev.EventID, "err", herr)
					stopped[pk] = true
					return
				}
			}
			safe = append(safe, rec)
		})
		if len(safe) > 0 {
			if err := c.cl.CommitRecords(ctx, safe...); err != nil {
				c.log.Warn("commit failed; records will replay (dedup downstream)", "err", err)
			}
		}
	}
}

func toRawEvent(rec *kgo.Record) RawEvent {
	ev := RawEvent{
		Topic:     rec.Topic,
		Key:       string(rec.Key),
		Partition: rec.Partition,
		Offset:    rec.Offset,
		Value:     rec.Value,
	}
	for _, h := range rec.Headers {
		if h.Key == "event_id" || h.Key == "eventId" {
			ev.EventID = string(h.Value)
			break
		}
	}
	if ev.EventID == "" {
		var body struct {
			EventID      string `json:"eventId"`
			EventIDSnake string `json:"event_id"`
		}
		if err := json.Unmarshal(rec.Value, &body); err == nil {
			if body.EventID != "" {
				ev.EventID = body.EventID
			} else if body.EventIDSnake != "" {
				ev.EventID = body.EventIDSnake
			}
		}
	}
	if ev.EventID == "" {
		ev.EventID = fmt.Sprintf("%s/%d/%d", rec.Topic, rec.Partition, rec.Offset)
	}
	return ev
}
