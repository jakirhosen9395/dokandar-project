import { test } from "node:test";
import assert from "node:assert/strict";
import { IdemCommands } from "../src/app/idem.js";
import { ApiError } from "../src/http/router.js";
import type { PgDb, PgTx } from "../src/persistence/pg.js";
import type { IdemStore, StoredResponse } from "../src/store/spine.js";
import { createHash } from "node:crypto";

const hashOf = (o: unknown): string =>
  createHash("sha256").update(JSON.stringify(o), "utf8").digest("hex");

function fakes(existing: StoredResponse | null) {
  const inserted: Array<{ status: number; body: string }> = [];
  const idemStore = {
    find: async () => existing,
    insert: async (_tx: PgTx, _k: string, _e: string, _h: string, status: number, body: string) => {
      inserted.push({ status, body });
    },
  } as unknown as IdemStore;
  const db = {
    withTx: async <T>(fn: (tx: PgTx) => Promise<T>) => fn({} as PgTx),
  } as unknown as PgDb;
  return { db, idemStore, inserted };
}

test("fresh key runs prepare then action and stores the response", async () => {
  const { db, idemStore, inserted } = fakes(null);
  const order: string[] = [];
  const cmd = new IdemCommands(db, idemStore);
  const out = await cmd.run("k", "POST /x", { a: 1 }, 201,
    async () => { order.push("action"); return { ok: true }; },
    async () => { order.push("prepare"); });
  assert.deepEqual(order, ["prepare", "action"]);
  assert.equal(out.status, 201);
  assert.equal(inserted.length, 1);
});

test("replayed key skips prepare and action entirely", async () => {
  const stored: StoredResponse = {
    requestHash: hashOf({ a: 1 }),
    status: 201, bodyJson: '{"ord":"ORD-1"}',
  };
  const { db, idemStore } = fakes(stored);
  let ran = false;
  const cmd = new IdemCommands(db, idemStore);
  const out = await cmd.run("k", "POST /x", { a: 1 }, 201,
    async () => { ran = true; return {}; }, async () => { ran = true; });
  assert.equal(ran, false);
  assert.equal(out.replayed, true);
});

test("stored business failure replays as the same ApiError", async () => {
  const stored: StoredResponse = {
    requestHash: hashOf({ a: 1 }),
    status: 409, bodyJson: '{"__error":{"code":"dokandar.b2c.order.insufficient_stock","message":"no stock"}}',
  };
  const { db, idemStore } = fakes(stored);
  const cmd = new IdemCommands(db, idemStore);
  await assert.rejects(cmd.run("k", "POST /x", { a: 1 }, 201, async () => ({})),
    (e: unknown) => e instanceof ApiError && e.status === 409 && e.code.includes("insufficient_stock"));
});

test("business rejection from the action is persisted for replay", async () => {
  const { db, idemStore, inserted } = fakes(null);
  const cmd = new IdemCommands(db, idemStore);
  await assert.rejects(cmd.run("k", "POST /x", { a: 1 }, 201, async () => {
    throw new ApiError(409, "dokandar.b2c.order.insufficient_stock", "no stock");
  }));
  assert.equal(inserted.length, 1);
  assert.equal(inserted[0].status, 409);
  assert.match(inserted[0].body, /__error/);
});

test("same key different body is a 409 conflict", async () => {
  const stored: StoredResponse = { requestHash: "different", status: 201, bodyJson: "{}" };
  const { db, idemStore } = fakes(stored);
  const cmd = new IdemCommands(db, idemStore);
  await assert.rejects(cmd.run("k", "POST /x", { a: 2 }, 201, async () => ({})),
    (e: unknown) => e instanceof ApiError && e.code.includes("idempotency_key_reuse"));
});
