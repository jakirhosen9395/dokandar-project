package messaging

import "context"

// Publisher / Consumer are the event-bus abstractions. Concrete Kafka (Redpanda) and RabbitMQ
// clients implement them at the integration point. No business events are defined here (R6: events
// are the Published Language; payloads come from the contracts).
type Publisher interface {
	Publish(ctx context.Context, topic string, key string, payload []byte) error
	Close() error
}

type Consumer interface {
	Subscribe(ctx context.Context, topics []string, handle func(topic string, key string, payload []byte) error) error
	Close() error
}

// KafkaConfig / RabbitConfig hold connection settings; Bootstrap wires the chosen driver.
type KafkaConfig struct{ Brokers string }
type RabbitConfig struct{ URL string }

// NoopPublisher is a safe default for local runs without a broker; replace with the real driver.
type NoopPublisher struct{}

func (NoopPublisher) Publish(context.Context, string, string, []byte) error { return nil }
func (NoopPublisher) Close() error                                          { return nil }
