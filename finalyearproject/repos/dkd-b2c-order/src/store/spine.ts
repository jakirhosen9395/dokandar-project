// R6 spine mechanics (fleet-standard): transactional outbox, consumer inbox dedup,
// command idempotency stored in the SAME transaction as the state change.
import type { PgDb, PgTx } from "../persistence/pg.js";

export interface OutboxRow {
  id: number; eventId: string; topic: string; partitionKey: string; payload: string; occurredAt: number;
}

export class OutboxStore {
  constructor(private readonly db: PgDb) {}

  async insert(tx: PgTx, eventId: string, topic: string, partitionKey: string,
               payloadJson: string, occurredAt: number): Promise<void> {
    await tx.exec(
      "INSERT INTO outbox(event_id, topic, partition_key, payload, occurred_at) VALUES ($1,$2,$3,$4::jsonb,$5)",
      [eventId, topic, partitionKey, payloadJson, occurredAt]);
  }

  async fetchUnpublished(limit: number): Promise<OutboxRow[]> {
    const rows = await this.db.query(
      "SELECT id, event_id, topic, partition_key, payload::text AS payload, occurred_at " +
      "FROM outbox WHERE published_at IS NULL ORDER BY id LIMIT $1", [Math.min(Math.max(limit, 1), 500)]);
    return rows.map((r) => ({
      id: Number(r["id"]), eventId: String(r["event_id"]), topic: String(r["topic"]),
      partitionKey: String(r["partition_key"]), payload: String(r["payload"]),
      occurredAt: Number(r["occurred_at"]),
    }));
  }

  async markPublished(id: number, now: number): Promise<void> {
    await this.db.query("UPDATE outbox SET published_at = $1 WHERE id = $2", [now, id]);
  }
}

export class InboxStore {
  /** @returns true when this event has not been processed before (row inserted now, in-tx). */
  async tryMark(tx: PgTx, eventId: string, topic: string, now: number): Promise<boolean> {
    const rows = await tx.query(
      "INSERT INTO inbox(event_id, topic, processed_at) VALUES ($1,$2,$3) " +
      "ON CONFLICT (event_id) DO NOTHING RETURNING event_id", [eventId, topic, now]);
    return rows.length === 1;
  }
}

export interface StoredResponse { requestHash: string; status: number; bodyJson: string }

export class IdemStore {
  constructor(private readonly db: PgDb) {}

  async find(idemKey: string, endpoint: string): Promise<StoredResponse | null> {
    const rows = await this.db.query(
      "SELECT request_hash, response_status, response_body::text AS body FROM cmd_idempotency " +
      "WHERE idem_key = $1 AND endpoint = $2", [idemKey, endpoint]);
    if (rows.length === 0) return null;
    return {
      requestHash: String(rows[0]["request_hash"]),
      status: Number(rows[0]["response_status"]),
      bodyJson: String(rows[0]["body"]),
    };
  }

  /** Insert inside the command transaction; a PK collision aborts the tx (concurrent duplicate). */
  async insert(tx: PgTx, idemKey: string, endpoint: string, requestHash: string,
               status: number, bodyJson: string, now: number): Promise<void> {
    await tx.exec(
      "INSERT INTO cmd_idempotency(idem_key, endpoint, request_hash, response_status, response_body, created_at) " +
      "VALUES ($1,$2,$3,$4,$5::jsonb,$6)", [idemKey, endpoint, requestHash, status, bodyJson, now]);
  }
}
