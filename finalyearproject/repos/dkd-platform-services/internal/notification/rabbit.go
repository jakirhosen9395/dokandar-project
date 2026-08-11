// RabbitMQ dispatch fabric — intra-context ONLY (R6: no queue crosses a context boundary).
// notification-svc both enqueues to and consumes platform.notification-dispatch.
package notification

import (
	"context"
	"fmt"
	"sync"
	"time"

	"log/slog"

	amqp "github.com/rabbitmq/amqp091-go"
)

const QueueDispatch = "platform.notification-dispatch"

type Rabbit struct {
	url  string
	log  *slog.Logger
	mu   sync.Mutex
	conn *amqp.Connection
	ch   *amqp.Channel
}

func NewRabbit(url string, log *slog.Logger) *Rabbit {
	return &Rabbit{url: url, log: log}
}

func (r *Rabbit) channel() (*amqp.Channel, error) {
	if r.conn == nil || r.conn.IsClosed() {
		conn, err := amqp.Dial(r.url)
		if err != nil {
			return nil, fmt.Errorf("rabbit: dial: %w", err)
		}
		r.conn = conn
		r.ch = nil
	}
	if r.ch == nil || r.ch.IsClosed() {
		ch, err := r.conn.Channel()
		if err != nil {
			return nil, fmt.Errorf("rabbit: channel: %w", err)
		}
		if _, err := ch.QueueDeclare(QueueDispatch, true, false, false, false, nil); err != nil {
			return nil, fmt.Errorf("rabbit: declare: %w", err)
		}
		r.ch = ch
	}
	return r.ch, nil
}

// PublishDispatch wakes a dispatch worker for one job (the job ROW is the durable item).
func (r *Rabbit) PublishDispatch(ntfID string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	ch, err := r.channel()
	if err != nil {
		return err
	}
	return ch.Publish("", QueueDispatch, false, false, amqp.Publishing{
		DeliveryMode: amqp.Persistent,
		ContentType:  "text/plain",
		Body:         []byte(ntfID),
	})
}

// RunDispatcher consumes the queue on its OWN connection and delivers via the adapter;
// fail() parks a job whose retries are exhausted.
func (r *Rabbit) RunDispatcher(ctx context.Context,
	deliver func(context.Context, string) error, fail func(context.Context, string) error) {
	for ctx.Err() == nil {
		if err := r.consumeLoop(ctx, deliver, fail); err != nil && ctx.Err() == nil {
			r.log.Error("dispatcher reconnecting", "err", err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(3 * time.Second):
			}
		}
	}
}

func (r *Rabbit) consumeLoop(ctx context.Context,
	deliver func(context.Context, string) error, fail func(context.Context, string) error) error {
	conn, err := amqp.Dial(r.url)
	if err != nil {
		return err
	}
	defer func() { _ = conn.Close() }()
	ch, err := conn.Channel()
	if err != nil {
		return err
	}
	if _, err := ch.QueueDeclare(QueueDispatch, true, false, false, false, nil); err != nil {
		return err
	}
	msgs, err := ch.Consume(QueueDispatch, "", false, false, false, false, nil)
	if err != nil {
		return err
	}
	// Bounded retries with backoff (reviewer H-2): a stuck job must never spin-loop the
	// dispatcher. After maxRetries the job is parked FAILED (never silently dropped).
	const maxRetries = 5
	retries := map[string]int{}
	for {
		select {
		case <-ctx.Done():
			return nil
		case msg, ok := <-msgs:
			if !ok {
				return fmt.Errorf("rabbit: channel closed")
			}
			ntf := string(msg.Body)
			if err := deliver(ctx, ntf); err != nil {
				retries[ntf]++
				if retries[ntf] >= maxRetries {
					r.log.Error("delivery exhausted retries — parking FAILED", "ntf", ntf, "err", err)
					if fErr := fail(ctx, ntf); fErr != nil {
						r.log.Error("park failed", "ntf", ntf, "err", fErr)
					}
					delete(retries, ntf)
					if aErr := msg.Ack(false); aErr != nil {
						r.log.Warn("ack failed", "err", aErr)
					}
					continue
				}
				r.log.Warn("delivery failed — backoff+requeue", "ntf", ntf,
					"attempt", retries[ntf], "err", err)
				select {
				case <-ctx.Done():
					return nil
				case <-time.After(time.Duration(retries[ntf]) * 2 * time.Second):
				}
				if nErr := msg.Nack(false, true); nErr != nil {
					r.log.Warn("nack failed", "err", nErr)
				}
				continue
			}
			delete(retries, ntf)
			if aErr := msg.Ack(false); aErr != nil {
				r.log.Warn("ack failed", "err", aErr)
			}
		}
	}
}

func (r *Rabbit) Close() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.conn != nil && !r.conn.IsClosed() {
		_ = r.conn.Close()
	}
}
