package messaging

import (
	"context"
	"encoding/json"
	"log/slog"
	"time"

	"github.com/segmentio/kafka-go"
	"gorm.io/gorm"

	"github.com/dokandar/dokandar-wallet/internal/observability"
)

// OutboxRelay polls the transactional outbox and ships rows to Kafka with
// acks=all, marking sent_at on success. It also keeps the wallet_outbox_pending
// gauge current. Adaptive idle backoff: fast when there is work, slow when idle.
type OutboxRelay struct {
	DB        *gorm.DB
	Writer    *kafka.Writer
	Interval  time.Duration
	BatchSize int
}

// NewWriter builds a hash-partitioned, acks=all writer. Returns nil when no
// brokers are configured (relay then disables itself).
func NewWriter(brokers string) *kafka.Writer {
	if brokers == "" {
		return nil
	}
	return &kafka.Writer{
		Addr:                   kafka.TCP(brokers),
		Balancer:               &kafka.Hash{},
		RequiredAcks:           kafka.RequireAll,
		BatchTimeout:           200 * time.Millisecond,
		AllowAutoTopicCreation: true,
	}
}

func (r *OutboxRelay) Run(ctx context.Context) {
	if r.Writer == nil || r.DB == nil {
		slog.Warn("outbox relay disabled (no writer or db)", "name", "wallet.outbox")
		return
	}
	base := r.Interval
	if base == 0 {
		base = 500 * time.Millisecond
	}
	if r.BatchSize == 0 {
		r.BatchSize = 100
	}
	idle := base
	const maxIdle = 5 * time.Second
	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(idle):
			n, err := r.tick(ctx)
			if err != nil {
				slog.Warn("outbox tick failed", "name", "wallet.outbox", "err", err.Error())
				idle = maxIdle
				continue
			}
			if n > 0 {
				idle = base // keep draining quickly
			} else if idle < maxIdle {
				idle *= 2
				if idle > maxIdle {
					idle = maxIdle
				}
			}
			r.updateGauge(ctx)
		}
	}
}

type outboxRow struct {
	ID      int64
	Topic   string
	Key     *string
	Payload []byte
}

func (r *OutboxRelay) tick(ctx context.Context) (int, error) {
	var shipped int
	err := r.DB.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		rows, err := tx.Raw(`
			SELECT id, topic, key, payload FROM outbox
			WHERE sent_at IS NULL ORDER BY id LIMIT ?
			FOR UPDATE SKIP LOCKED`, r.BatchSize).Rows()
		if err != nil {
			return err
		}
		batch := []outboxRow{}
		for rows.Next() {
			var row outboxRow
			var payload []byte
			if err := rows.Scan(&row.ID, &row.Topic, &row.Key, &payload); err != nil {
				rows.Close()
				return err
			}
			// jsonb column → raw JSON bytes; pass through to Kafka verbatim.
			var raw json.RawMessage
			if json.Unmarshal(payload, &raw) == nil {
				row.Payload = []byte(raw)
			} else {
				row.Payload = payload
			}
			batch = append(batch, row)
		}
		rows.Close()
		if len(batch) == 0 {
			return nil
		}

		msgs := make([]kafka.Message, 0, len(batch))
		ids := make([]int64, 0, len(batch))
		for _, row := range batch {
			m := kafka.Message{Topic: row.Topic, Value: row.Payload}
			if row.Key != nil {
				m.Key = []byte(*row.Key)
			}
			msgs = append(msgs, m)
			ids = append(ids, row.ID)
		}
		wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		if err := r.Writer.WriteMessages(wctx, msgs...); err != nil {
			return err
		}
		// GORM expands a []int64 into an IN (...) list — do not use ANY(?),
		// which would receive a Go slice the driver can't bind.
		if err := tx.Exec(`UPDATE outbox SET sent_at = now() WHERE id IN ?`, ids).Error; err != nil {
			return err
		}
		shipped = len(batch)
		return nil
	})
	if err != nil {
		return 0, err
	}
	if shipped > 0 {
		observability.WalletOutboxPublishedTotal.WithLabelValues(observability.ServiceVal).Add(float64(shipped))
	}
	return shipped, nil
}

func (r *OutboxRelay) updateGauge(ctx context.Context) {
	var n int64
	c, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()
	if err := r.DB.WithContext(c).Raw(`SELECT count(*) FROM outbox WHERE sent_at IS NULL`).Scan(&n).Error; err == nil {
		observability.WalletOutboxPending.WithLabelValues(observability.ServiceVal).Set(float64(n))
	}
}
