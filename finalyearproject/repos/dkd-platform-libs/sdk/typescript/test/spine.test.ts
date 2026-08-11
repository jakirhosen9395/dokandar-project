// PL-02 conformance — transactional outbox + consumer inbox + DLQ park-and-freeze.
// Driven by an IN-MEMORY FAKE DbExecutor that records every SQL string + params it is
// issued, so the contract is provable WITHOUT a live Postgres (unit-testable, driver-agnostic).
import { test } from "node:test";
import assert from "node:assert/strict";
import { Outbox, OutboxRelay, type DbExecutor, type QueryResult } from "../src/outbox.js";
import { Inbox } from "../src/inbox.js";
import { Dlq } from "../src/dlq.js";

interface Issued {
  sql: string;
  params: readonly unknown[];
}

/**
 * A fake DbExecutor that records issued statements and answers via a programmable responder.
 * It models the two behaviours the helpers depend on: ON CONFLICT DO NOTHING (rowCount 0/1)
 * and SELECT existence (rows/rowCount).
 */
class FakeDb implements DbExecutor {
  readonly issued: Issued[] = [];
  private responder: (sql: string, params: readonly unknown[]) => QueryResult = () => ({
    rows: [],
    rowCount: 0,
  });

  respondWith(fn: (sql: string, params: readonly unknown[]) => QueryResult): void {
    this.responder = fn;
  }

  async query(sql: string, params: readonly unknown[]): Promise<QueryResult> {
    this.issued.push({ sql, params });
    return this.responder(sql, params);
  }

  last(): Issued {
    return this.issued[this.issued.length - 1];
  }
}

test("Outbox.enqueue issues one INSERT with ON CONFLICT DO NOTHING and the right columns", async () => {
  const db = new FakeDb();
  db.respondWith(() => ({ rows: [], rowCount: 1 }));

  const inserted = await Outbox.enqueue(db, {
    eventId: "evt-1",
    topic: "custody.passport.CustodyInitialized.v1",
    key: "PP-1",
    payload: '{"ppid":"PP-1"}',
    occurredAtMs: 1_700_000_000_000,
  });

  assert.equal(inserted, true);
  assert.equal(db.issued.length, 1);
  const { sql, params } = db.last();
  assert.match(sql, /INSERT INTO outbox\(event_id, topic, key, payload, occurred_at_ms\)/);
  assert.match(sql, /ON CONFLICT \(event_id\) DO NOTHING/);
  assert.match(sql, /\$4::jsonb/); // payload cast to jsonb at the boundary
  assert.deepEqual(params, [
    "evt-1",
    "custody.passport.CustodyInitialized.v1",
    "PP-1",
    '{"ppid":"PP-1"}',
    1_700_000_000_000,
  ]);
});

test("Outbox.enqueue on a duplicate event_id is a no-op (returns false)", async () => {
  const db = new FakeDb();
  db.respondWith(() => ({ rows: [], rowCount: 0 })); // ON CONFLICT fired: no row inserted

  const inserted = await Outbox.enqueue(db, {
    eventId: "evt-1",
    topic: "t",
    key: "k",
    payload: "{}",
    occurredAtMs: 1,
  });

  assert.equal(inserted, false);
});

test("OutboxRelay.fetchUnpublished selects unpublished rows in id order and maps them", async () => {
  const db = new FakeDb();
  db.respondWith(() => ({
    rows: [
      { id: 7, event_id: "e7", topic: "t", key: "k7", payload: "{}", occurred_at_ms: 10 },
    ],
    rowCount: 1,
  }));

  const rows = await OutboxRelay.fetchUnpublished(db, 200);

  const { sql, params } = db.last();
  assert.match(sql, /WHERE published_at IS NULL ORDER BY id LIMIT \$1/);
  assert.deepEqual(params, [200]);
  assert.deepEqual(rows, [
    { id: 7, eventId: "e7", topic: "t", key: "k7", payload: "{}", occurredAtMs: 10 },
  ]);
});

test("OutboxRelay.markPublished stamps published_at for the produced prefix", async () => {
  const db = new FakeDb();
  await OutboxRelay.markPublished(db, [7, 8, 9]);
  const { sql, params } = db.last();
  assert.match(sql, /UPDATE outbox SET published_at = now\(\) WHERE id = ANY\(\$1\)/);
  assert.deepEqual(params, [[7, 8, 9]]);
});

test("OutboxRelay.markPublished is a no-op on an empty prefix", async () => {
  const db = new FakeDb();
  await OutboxRelay.markPublished(db, []);
  assert.equal(db.issued.length, 0);
});

test("OutboxRelay.headersFor stamps event_id + producer_context; traceparent is stub-safe", () => {
  const row = { id: 1, eventId: "e1", topic: "t", key: "k", payload: "{}", occurredAtMs: 1 };

  const bare = OutboxRelay.headersFor(row, "custody");
  assert.deepEqual(bare, { event_id: "e1", producer_context: "custody" });
  assert.equal("traceparent" in bare, false); // not fabricated when absent

  // PL-05: a VALID W3C traceparent is injected; a malformed one is dropped, not propagated.
  const tp = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
  const traced = OutboxRelay.headersFor(row, "custody", tp);
  assert.equal(traced.traceparent, tp); // valid W3C traceparent injected
  const badlyTraced = OutboxRelay.headersFor(row, "custody", "00-abc-def-01");
  assert.equal(badlyTraced.traceparent, undefined); // malformed dropped
});

test("Inbox.markProcessed then alreadyProcessed(true); dedup is per (consumer, event_id)", async () => {
  const db = new FakeDb();

  db.respondWith(() => ({ rows: [], rowCount: 1 })); // first claim inserts
  const claimed = await Inbox.markProcessed(db, "inventory-svc", "evt-1");
  assert.equal(claimed, true);
  let { sql, params } = db.last();
  assert.match(sql, /INSERT INTO inbox\(consumer, event_id, processed_at\)/);
  assert.match(sql, /ON CONFLICT \(consumer, event_id\) DO NOTHING/);
  assert.deepEqual(params, ["inventory-svc", "evt-1"]);

  db.respondWith(() => ({ rows: [{ "?column?": 1 }], rowCount: 1 })); // now it exists
  const seen = await Inbox.alreadyProcessed(db, "inventory-svc", "evt-1");
  assert.equal(seen, true);
  ({ sql, params } = db.last());
  assert.match(sql, /SELECT 1 FROM inbox WHERE consumer = \$1 AND event_id = \$2/);
  assert.deepEqual(params, ["inventory-svc", "evt-1"]);
});

test("Inbox.alreadyProcessed is false for an unseen event", async () => {
  const db = new FakeDb();
  db.respondWith(() => ({ rows: [], rowCount: 0 }));
  assert.equal(await Inbox.alreadyProcessed(db, "inventory-svc", "evt-x"), false);
});

test("Inbox.markProcessed on a redelivery returns false (already claimed)", async () => {
  const db = new FakeDb();
  db.respondWith(() => ({ rows: [], rowCount: 0 })); // ON CONFLICT fired
  assert.equal(await Inbox.markProcessed(db, "inventory-svc", "evt-1"), false);
});

test("Dlq.park records aggregate_key; isKeyParked is true ONLY for that key", async () => {
  const db = new FakeDb();
  db.respondWith(() => ({ rows: [], rowCount: 1 }));

  await Dlq.park(db, {
    eventId: "evt-poison",
    topic: "finance.wallet.WalletDebited.v1",
    key: "WLT-9",
    payload: '{"amount":500}',
    error: "boom: invariant violated",
    aggregateKey: "WLT-9",
  });
  const parked = db.last();
  assert.match(parked.sql, /INSERT INTO dlq\(event_id, topic, key, payload, error, aggregate_key, parked_at\)/);
  assert.match(parked.sql, /\$4::jsonb/);
  assert.deepEqual(parked.params, [
    "evt-poison",
    "finance.wallet.WalletDebited.v1",
    "WLT-9",
    '{"amount":500}',
    "boom: invariant violated",
    "WLT-9",
  ]);

  // The frozen key is parked...
  db.respondWith((_sql, params) =>
    params[0] === "WLT-9" ? { rows: [{ "?column?": 1 }], rowCount: 1 } : { rows: [], rowCount: 0 },
  );
  assert.equal(await Dlq.isKeyParked(db, "WLT-9"), true);
  assert.match(db.last().sql, /SELECT 1 FROM dlq WHERE aggregate_key = \$1 LIMIT 1/);

  // ...but every OTHER aggregate key keeps flowing.
  assert.equal(await Dlq.isKeyParked(db, "WLT-42"), false);
});
