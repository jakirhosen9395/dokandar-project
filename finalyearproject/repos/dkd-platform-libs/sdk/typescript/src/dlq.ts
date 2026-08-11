// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// Dead-letter quarantine with per-key park-and-freeze (SA-MSG-09/10). A poison money/custody/
// inventory event is parked to the DLQ and its aggregate_key is FROZEN — only that key stops
// advancing while every other key keeps flowing. Nothing is ever silently dropped.
// One of five byte-identical language implementations sharing the SAME contract (PL-02).
import type { DbExecutor } from "./outbox.js";

export interface ParkedEvent {
  eventId: string;
  topic: string;
  key: string;
  /** Serialized canonical JSON of the offending event — cast to jsonb at the boundary. */
  payload: string;
  error: string;
  /** The single aggregate key to freeze (e.g. WLT/ESC/TXN, PPID). */
  aggregateKey: string;
}

export class Dlq {
  /** Quarantine a poison event and freeze ONLY its aggregate key. */
  static async park(db: DbExecutor, ev: ParkedEvent): Promise<void> {
    await db.query(
      "INSERT INTO dlq(event_id, topic, key, payload, error, aggregate_key, parked_at) " +
        "VALUES ($1,$2,$3,$4::jsonb,$5,$6,now())",
      [ev.eventId, ev.topic, ev.key, ev.payload, ev.error, ev.aggregateKey],
    );
  }

  /**
   * True when this aggregate key has a parked (frozen) event. A consumer checks this before
   * processing to keep the frozen key stalled while other keys progress.
   */
  static async isKeyParked(db: DbExecutor, aggregateKey: string): Promise<boolean> {
    const res = await db.query(
      "SELECT 1 FROM dlq WHERE aggregate_key = $1 LIMIT 1",
      [aggregateKey],
    );
    return res.rowCount >= 1;
  }
}
