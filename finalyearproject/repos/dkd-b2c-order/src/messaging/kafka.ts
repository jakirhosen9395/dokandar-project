// Concrete Kafka (Redpanda/Kafka-class) adapter over kafkajs — the R6 Published Language.
// Producer: headers event_id + producer_context=b2c (fleet byte-compatible). Consumer:
// per-record handling; a thrown error pauses redelivery-loop on that partition (park-and-freeze
// for order-critical topics — nothing silently dropped); inbox dedup is the caller's job (in-tx).
import { Kafka, logLevel, type Producer as KProducer, type Consumer as KConsumer } from "kafkajs";
import kafkajsCjs from "kafkajs";
import SnappyCodec from "kafkajs-snappy";

// The Go fleet (franz-go) produces snappy-compressed batches; kafkajs needs the codec wired.
// CompressionCodecs is not a statically-analyzable CJS export — reach it via the default import.
const kj = kafkajsCjs as unknown as {
  CompressionTypes: { Snappy: number };
  CompressionCodecs: Record<number, unknown>;
};
kj.CompressionCodecs[kj.CompressionTypes.Snappy] = SnappyCodec;

export interface SpineRecord {
  topic: string;
  key: string;
  eventId: string;
  payload: Record<string, unknown>;
}

export class KafkaSpine {
  private readonly kafka: Kafka;
  private producer?: KProducer;
  private consumer?: KConsumer;

  constructor(brokers: string, private readonly clientId: string) {
    this.kafka = new Kafka({ clientId, brokers: brokers.split(","), logLevel: logLevel.WARN });
  }

  async connectProducer(): Promise<void> {
    this.producer = this.kafka.producer({ idempotent: true, maxInFlightRequests: 1 });
    await this.producer.connect();
  }

  async publish(topic: string, key: string, eventId: string, payloadJson: string): Promise<void> {
    if (!this.producer) throw new Error("producer not connected");
    await this.producer.send({
      topic,
      acks: -1,
      messages: [{
        key,
        value: payloadJson,
        headers: { event_id: eventId, producer_context: "b2c" },
      }],
    });
  }

  /** Extracts event_id header first, payload eventId/event_id second, synthetic last. */
  static eventIdOf(topic: string, partition: number, offset: string,
                   headers: Record<string, Buffer | string | undefined> | undefined,
                   payload: Record<string, unknown>): string {
    const h = headers?.["event_id"];
    if (h) return h.toString();
    const p = payload["eventId"] ?? payload["event_id"];
    if (typeof p === "string" && p !== "") return p;
    return `${topic}/${partition}/${offset}`;
  }

  async subscribe(groupId: string, topics: string[],
                  handle: (rec: SpineRecord) => Promise<void>,
                  log: (msg: string, fields?: Record<string, unknown>) => void): Promise<void> {
    this.consumer = this.kafka.consumer({ groupId });
    await this.consumer.connect();
    for (const t of topics) await this.consumer.subscribe({ topic: t, fromBeginning: false });
    await this.consumer.run({
      eachMessage: async ({ topic, partition, message }) => {
        let payload: Record<string, unknown> = {};
        try {
          payload = JSON.parse(message.value?.toString() ?? "{}") as Record<string, unknown>;
        } catch {
          log("unparseable spine payload — treated as empty", { topic });
        }
        const eventId = KafkaSpine.eventIdOf(
          topic, partition, message.offset, message.headers as Record<string, Buffer>, payload);
        await handle({ topic, key: message.key?.toString() ?? "", eventId, payload });
      },
    });
  }

  async close(): Promise<void> {
    await this.consumer?.disconnect();
    await this.producer?.disconnect();
  }
}
