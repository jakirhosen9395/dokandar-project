// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// Transactional outbox — the "T" of SA-CONV-QUARTET (outbox+inbox = effectively-once,
// EF §21.1 / EF-EVT-6). The aggregate write and the outbox INSERT commit in ONE local
// transaction supplied by the caller; a background relay drains rows to the R6 spine.
// One of five byte-identical language implementations sharing the SAME contract (PL-02).
import { type TraceParent, formatTraceparent, parseTraceparent } from "./trace.js";

/** Minimal driver-agnostic DB handle. `pg`'s `Client`/`PoolClient`/tx wrapper all satisfy this. */
export interface DbExecutor {
  query(sql: string, params: readonly unknown[]): Promise<QueryResult>;
}

export interface QueryResult {
  rows: Array<Record<string, unknown>>;
  rowCount: number;
}

/** Canonical outbox schema (DM/EF): payload is JSONB, occurred_at_ms is int64 unix millis. */
export interface OutboxEvent {
  eventId: string;
  topic: string;
  key: string;
  /** Serialized canonical JSON (IDs only, never PII) — cast to jsonb at the boundary. */
  payload: string;
  occurredAtMs: number;
}

export interface OutboxRow {
  id: number;
  eventId: string;
  topic: string;
  key: string;
  payload: string;
  occurredAtMs: number;
}

/** Headers the relay stamps on every produced record (dedup + trace propagation). */
export interface SpineHeaders {
  event_id: string;
  producer_context: string;
  traceparent?: string;
}

export class Outbox {
  /**
   * Insert the outbox row using the CALLER-PROVIDED tx handle (atomic with the aggregate
   * write). Idempotent: a repeated event_id is a no-op (ON CONFLICT DO NOTHING).
   * @returns true when a new row was inserted, false when it already existed.
   */
  static async enqueue(tx: DbExecutor, ev: OutboxEvent): Promise<boolean> {
    const res = await tx.query(
      "INSERT INTO outbox(event_id, topic, key, payload, occurred_at_ms) " +
        "VALUES ($1,$2,$3,$4::jsonb,$5) ON CONFLICT (event_id) DO NOTHING",
      [ev.eventId, ev.topic, ev.key, ev.payload, ev.occurredAtMs],
    );
    return res.rowCount === 1;
  }
}

export class OutboxRelay {
  /** Publisher loop: rows in strict id order, never skipping ahead of a failed row. */
  static async fetchUnpublished(db: DbExecutor, limit: number): Promise<OutboxRow[]> {
    const bounded = Math.min(Math.max(Math.trunc(limit), 1), 500);
    const res = await db.query(
      "SELECT id, event_id, topic, key, payload::text AS payload, occurred_at_ms " +
        "FROM outbox WHERE published_at IS NULL ORDER BY id LIMIT $1",
      [bounded],
    );
    return res.rows.map((r) => ({
      id: Number(r["id"]),
      eventId: String(r["event_id"]),
      topic: String(r["topic"]),
      key: String(r["key"]),
      payload: String(r["payload"]),
      occurredAtMs: Number(r["occurred_at_ms"]),
    }));
  }

  /** Mark the successfully produced prefix published (at-least-once; consumers dedup by inbox). */
  static async markPublished(db: DbExecutor, ids: readonly number[]): Promise<void> {
    if (ids.length === 0) return;
    await db.query(
      "UPDATE outbox SET published_at = now() WHERE id = ANY($1)",
      [ids.slice()],
    );
  }

  /**
   * Headers stamped on the produced record (PL-05: W3C trace context injected into the EVENT
   * headers). `traceparent` is stub-safe: injected when the caller supplies an active trace
   * context, omitted otherwise (never fabricated). Accepts either a parsed {@link TraceParent}
   * or a raw wire string — a malformed string is dropped rather than propagated.
   */
  static headersFor(
    row: OutboxRow,
    producerContext: string,
    traceparent?: TraceParent | string,
  ): SpineHeaders {
    const headers: SpineHeaders = {
      event_id: row.eventId,
      producer_context: producerContext,
    };
    if (typeof traceparent === "string") {
      const parsed = parseTraceparent(traceparent);
      if (parsed) headers.traceparent = formatTraceparent(parsed);
    } else if (traceparent) {
      headers.traceparent = formatTraceparent(traceparent);
    }
    return headers;
  }
}
