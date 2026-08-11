// Kafka + RabbitMQ bootstrap abstractions. Concrete drivers (Redpanda/RabbitMQ) implement these at
// the integration point. No business events (R6: events are the Published Language).
export interface Publisher {
  publish(topic: string, key: string, payload: Uint8Array): Promise<void>;
  close(): Promise<void>;
}
export interface Consumer {
  subscribe(topics: string[], handle: (topic: string, key: string, payload: Uint8Array) => Promise<void>): Promise<void>;
  close(): Promise<void>;
}
export interface KafkaConfig { brokers: string; }
export interface RabbitConfig { url: string; }

export class NoopPublisher implements Publisher {
  async publish(): Promise<void> { /* wired to the broker at the integration point */ }
  async close(): Promise<void> { /* no-op */ }
}
