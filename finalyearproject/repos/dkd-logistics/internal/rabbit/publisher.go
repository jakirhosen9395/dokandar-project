// Package rabbit implements LOG-10: the intra-context RabbitMQ publisher for the
// logistics.rider-assignment and logistics.delivery-notification queues (R6-exempt — intra-context
// only, NOT the cross-context Published Language). No-op when DKD_RABBITMQ_URL is unset (dev).
package rabbit

import (
	"context"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
)

const (
	QueueRiderAssignment      = "logistics.rider-assignment"
	QueueDeliveryNotification = "logistics.delivery-notification"
)

type Publisher struct {
	conn *amqp.Connection
	ch   *amqp.Channel
}

// New dials RabbitMQ and declares the two durable intra-context queues. url="" -> a no-op
// publisher (dev), so the service never fails to boot when RabbitMQ is absent.
func New(url string) (*Publisher, error) {
	if url == "" {
		return &Publisher{}, nil
	}
	conn, err := amqp.Dial(url)
	if err != nil {
		return nil, err
	}
	ch, err := conn.Channel()
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	for _, q := range []string{QueueRiderAssignment, QueueDeliveryNotification} {
		if _, err := ch.QueueDeclare(q, true, false, false, false, nil); err != nil {
			_ = conn.Close()
			return nil, err
		}
	}
	return &Publisher{conn: conn, ch: ch}, nil
}

// Publish sends a JSON body to an intra-context queue. No-op on a nil/unconfigured publisher.
func (p *Publisher) Publish(queue string, body []byte) error {
	if p == nil || p.ch == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return p.ch.PublishWithContext(ctx, "", queue, false, false,
		amqp.Publishing{ContentType: "application/json", DeliveryMode: amqp.Persistent, Body: body})
}

func (p *Publisher) Close() {
	if p == nil {
		return
	}
	if p.ch != nil {
		_ = p.ch.Close()
	}
	if p.conn != nil {
		_ = p.conn.Close()
	}
}
