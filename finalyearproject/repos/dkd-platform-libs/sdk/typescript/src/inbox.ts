// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// Consumer inbox — the "I" of SA-CONV-QUARTET (EF §21.1 / EF-EVT-6). A consumer records the
// event_id in the SAME transaction as its side effect, so a redelivered event is a no-op.
// Keyed by (consumer, event_id): the same fact may be consumed independently by many contexts.
// One of five byte-identical language implementations sharing the SAME contract (PL-02).
import type { DbExecutor } from "./outbox.js";

export class Inbox {
  /** True when (consumer, eventId) was already processed — dedup guard, same tx as the effect. */
  static async alreadyProcessed(
    tx: DbExecutor,
    consumer: string,
    eventId: string,
  ): Promise<boolean> {
    const res = await tx.query(
      "SELECT 1 FROM inbox WHERE consumer = $1 AND event_id = $2",
      [consumer, eventId],
    );
    return res.rowCount >= 1;
  }

  /**
   * Record (consumer, eventId) as processed inside the effect's tx. Idempotent under concurrent
   * redelivery (ON CONFLICT DO NOTHING on the composite PK).
   * @returns true when this call claimed the event, false when already marked.
   */
  static async markProcessed(
    tx: DbExecutor,
    consumer: string,
    eventId: string,
  ): Promise<boolean> {
    const res = await tx.query(
      "INSERT INTO inbox(consumer, event_id, processed_at) VALUES ($1,$2,now()) " +
        "ON CONFLICT (consumer, event_id) DO NOTHING",
      [consumer, eventId],
    );
    return res.rowCount === 1;
  }
}
