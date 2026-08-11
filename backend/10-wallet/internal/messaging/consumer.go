package messaging

import (
	"context"
	"encoding/json"
	"log/slog"
	"time"

	"github.com/google/uuid"
	"github.com/segmentio/kafka-go"

	"github.com/dokandar/dokandar-wallet/internal/service"
)

// OrderPlacedConsumer drains dokandar.order.placed and grants cashback. It uses
// FetchMessage + CommitMessages so the offset is committed ONLY AFTER the
// handler's DB tx succeeds (commit-after-handle — at-least-once delivery made
// effectively-once by the cashback idempotency key). Degradable: disabled when
// no brokers/topic; reconnects on read error.
type OrderPlacedConsumer struct {
	Brokers string
	Topic   string
	GroupID string
	Service *service.Service
}

func (c *OrderPlacedConsumer) Run(ctx context.Context) {
	if c.Brokers == "" || c.Topic == "" {
		slog.Warn("order.placed consumer disabled (no brokers or topic)", "name", "wallet.cashback")
		return
	}
	for {
		if ctx.Err() != nil {
			return
		}
		reader := kafka.NewReader(kafka.ReaderConfig{
			Brokers:     []string{c.Brokers},
			GroupID:     c.GroupID,
			Topic:       c.Topic,
			StartOffset: kafka.LastOffset,
			MaxBytes:    10 << 20,
		})
		c.loop(ctx, reader)
		_ = reader.Close()
		if ctx.Err() != nil {
			return
		}
		time.Sleep(2 * time.Second) // backoff before reconnect
	}
}

func (c *OrderPlacedConsumer) loop(ctx context.Context, reader *kafka.Reader) {
	for {
		m, err := reader.FetchMessage(ctx)
		if err != nil {
			if ctx.Err() == nil {
				slog.Warn("order.placed read error", "name", "wallet.cashback", "err", err.Error())
			}
			return
		}
		c.handle(ctx, m)
		// Commit the offset AFTER the handler. If commit fails we will re-read
		// the message; the cashback idempotency key keeps it effectively-once.
		if err := reader.CommitMessages(ctx, m); err != nil {
			if ctx.Err() == nil {
				slog.Warn("order.placed commit error", "name", "wallet.cashback", "err", err.Error())
			}
			return
		}
	}
}

func (c *OrderPlacedConsumer) handle(ctx context.Context, m kafka.Message) {
	// Lenient multi-field parse (order.placed shapes vary): user_id|customer_id,
	// order_id|id, subtotal_minor|amount_minor.
	var ev struct {
		UserID        string `json:"user_id"`
		CustomerID    string `json:"customer_id"`
		OrderID       string `json:"order_id"`
		ID            string `json:"id"`
		SubtotalMinor int64  `json:"subtotal_minor"`
		AmountMinor   int64  `json:"amount_minor"`
	}
	if err := json.Unmarshal(m.Value, &ev); err != nil {
		return
	}
	uID := ev.UserID
	if uID == "" {
		uID = ev.CustomerID
	}
	oID := ev.OrderID
	if oID == "" {
		oID = ev.ID
	}
	subtotal := ev.SubtotalMinor
	if subtotal == 0 {
		subtotal = ev.AmountMinor
	}
	if uID == "" || oID == "" || subtotal <= 0 {
		return
	}
	uUUID, err := uuid.Parse(uID)
	if err != nil {
		return
	}
	oUUID, err := uuid.Parse(oID)
	if err != nil {
		return
	}
	if err := c.Service.GrantCashbackForOrder(ctx, uUUID, oUUID, subtotal); err != nil {
		slog.Warn("grant cashback failed", "name", "wallet.cashback", "err", err.Error())
	}
}
