// Outbox relay: at-least-once drain to the spine; stops at the first failure to
// preserve per-key ordering; consumers dedup on the event_id header.
import { OutboxStore } from "../store/spine.js";
import { KafkaSpine } from "../messaging/kafka.js";
import type { Logger } from "../obs/logging.js";

const TICK_MS = 700;
const BATCH = 200;

export class OutboxRelay {
  private timer?: NodeJS.Timeout;
  private draining = false;

  constructor(
    private readonly outbox: OutboxStore,
    private readonly spine: KafkaSpine,
    private readonly log: Logger,
  ) {}

  start(): void {
    this.timer = setInterval(() => void this.drain(), TICK_MS);
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
  }

  async drain(): Promise<void> {
    if (this.draining) return;
    this.draining = true;
    try {
      const rows = await this.outbox.fetchUnpublished(BATCH);
      for (const row of rows) {
        try {
          await this.spine.publish(row.topic, row.partitionKey, row.eventId, row.payload);
          await this.outbox.markPublished(row.id, Date.now());
        } catch (e) {
          this.log.error("outbox publish failed — retrying next tick", {
            eventId: row.eventId, topic: row.topic, err: String(e),
          });
          return; // keep ordering: never skip ahead of a failed row
        }
      }
    } catch (e) {
      this.log.error("outbox drain failed", { err: String(e) });
    } finally {
      this.draining = false;
    }
  }
}
