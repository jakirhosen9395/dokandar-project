import { test } from "node:test";
import assert from "node:assert/strict";

import { uuidv7, isUuidV7, assertUuidV7, timestampOf } from "../src/uuid7.js";
import { DID } from "../src/ids.js";
import {
  decide, remember, isUnsafeMethod, fingerprint,
  type IdempotencyStore, type IdempotencyRecord,
} from "../src/idempotency.js";
import {
  parseTraceparent, formatTraceparent, newSpanId, newTraceId,
  newRootTraceParent, childContext, injectTraceparent, extractTraceparent,
} from "../src/trace.js";
import { OutboxRelay, type OutboxRow } from "../src/outbox.js";
import {
  HttpStatus, statusForCategory, CATEGORY_STATUS,
  MalformedError, BusinessValidationError, AuthorizationError,
  LockedError, RateLimitError, StateConflictError,
} from "../src/errors.js";
import { OPENAPI_VERSION } from "../src/apidocs.js";

// ---------- PL-04: UUID v7 generator + validation ----------

test("PL-04: a v7 passes, a v4 and garbage fail", () => {
  const v7 = uuidv7();
  assert.ok(isUuidV7(v7), `generated id should be v7: ${v7}`);
  assert.equal(v7[14], "7"); // version nibble
  // a real v4 (version nibble 4) must be rejected
  assert.equal(isUuidV7("9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d"), false);
  // garbage / wrong shape
  assert.equal(isUuidV7("abc"), false);
  assert.equal(isUuidV7("0190b8e0-8f6a-7c3d-0a2b-1c4d5e6f7a8b"), false); // variant 0 invalid
  assert.throws(() => assertUuidV7("not-a-uuid"));
});

test("PL-04: generated IDs round-trip (timestamp + prefixed helper)", () => {
  const ts = 1_700_000_000_000;
  const id = uuidv7(ts);
  assert.equal(timestampOf(id), ts);
  // prefixed-ID helper validates the embedded UUID as v7
  const did = new DID("did:dokandar:" + id);
  assert.equal(did.value, "did:dokandar:" + id);
  // and mint() produces a valid one
  const minted = DID.mint();
  assert.ok(minted.value.startsWith("did:dokandar:"));
  assert.ok(isUuidV7(minted.value.slice("did:dokandar:".length)));
});

// ---------- PL-03: Idempotency-Key enforcement (3 branches) ----------

class FakeStore implements IdempotencyStore {
  readonly map = new Map<string, IdempotencyRecord>();
  async find(key: string): Promise<IdempotencyRecord | null> { return this.map.get(key) ?? null; }
  async save(rec: IdempotencyRecord): Promise<boolean> {
    if (this.map.has(rec.key)) return false;
    this.map.set(rec.key, rec);
    return true;
  }
}

test("PL-03: missing key on an unsafe write → 400", async () => {
  const store = new FakeStore();
  const out = await decide(store, { method: "POST", payload: "{}" });
  assert.equal(out.kind, "missing-key");
  if (out.kind === "missing-key") assert.equal(out.status, 400);
});

test("PL-03: same key + same payload → replay stored response", async () => {
  const store = new FakeStore();
  const first = await decide(store, { method: "POST", key: "k1", payload: '{"amt":100}' });
  assert.equal(first.kind, "proceed");
  if (first.kind === "proceed") await remember(store, first, 201, '{"id":"ORD-1"}', 123);
  const replay = await decide(store, { method: "POST", key: "k1", payload: '{"amt":100}' });
  assert.equal(replay.kind, "replay");
  if (replay.kind === "replay") {
    assert.equal(replay.status, 201);
    assert.equal(replay.record.responseBody, '{"id":"ORD-1"}');
  }
});

test("PL-03: same key + different payload → 409", async () => {
  const store = new FakeStore();
  const first = await decide(store, { method: "POST", key: "k2", payload: '{"amt":100}' });
  if (first.kind === "proceed") await remember(store, first, 201, "{}");
  const conflict = await decide(store, { method: "POST", key: "k2", payload: '{"amt":999}' });
  assert.equal(conflict.kind, "conflict");
  if (conflict.kind === "conflict") assert.equal(conflict.status, 409);
});

test("PL-03: safe methods proceed without a key; fingerprint is stable", async () => {
  const store = new FakeStore();
  const out = await decide(store, { method: "GET", payload: "" });
  assert.equal(out.kind, "proceed");
  assert.equal(isUnsafeMethod("post"), true);
  assert.equal(isUnsafeMethod("GET"), false);
  assert.equal(fingerprint("x"), fingerprint("x"));
  assert.notEqual(fingerprint("x"), fingerprint("y"));
});

// ---------- PL-05: W3C traceparent parse/format/inject/extract ----------

const GOOD_TP = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";

test("PL-05: parse↔format round-trip", () => {
  const tp = parseTraceparent(GOOD_TP);
  assert.ok(tp);
  assert.equal(formatTraceparent(tp!), GOOD_TP);
  assert.equal(tp!.traceId, "4bf92f3577b34da6a3ce929d0e0e4736");
  assert.equal(tp!.spanId, "00f067aa0ba902b7");
});

test("PL-05: reject malformed traceparent", () => {
  assert.equal(parseTraceparent(""), null);
  assert.equal(parseTraceparent("00-abc-def-01"), null);               // bad lengths
  assert.equal(parseTraceparent("ff-" + "0".repeat(32).replace(/0/g, "a") + "-00f067aa0ba902b7-01"), null); // ff version
  assert.equal(parseTraceparent("00-" + "0".repeat(32) + "-00f067aa0ba902b7-01"), null); // all-zero trace
  assert.equal(parseTraceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-" + "0".repeat(16) + "-01"), null); // all-zero span
  assert.equal(parseTraceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-0z"), null); // non-hex flags
  assert.equal(parseTraceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7"), null); // 3 fields
});

test("PL-05: new ids, child context, inject/extract on HTTP + event headers", () => {
  assert.match(newTraceId(), /^[0-9a-f]{32}$/);
  assert.match(newSpanId(), /^[0-9a-f]{16}$/);
  const root = newRootTraceParent();
  assert.ok(parseTraceparent(formatTraceparent(root)));
  const child = childContext(root);
  assert.equal(child.traceId, root.traceId);
  assert.notEqual(child.spanId, root.spanId);
  // inject into an outgoing HTTP header carrier
  const headers: Record<string, string> = {};
  injectTraceparent(headers, root);
  assert.equal(headers["traceparent"], formatTraceparent(root));
  // extract is case-insensitive
  const got = extractTraceparent({ TraceParent: formatTraceparent(root) });
  assert.equal(got?.traceId, root.traceId);
});

test("PL-05: OutboxRelay.headersFor injects a valid traceparent, drops a bad one", () => {
  const row: OutboxRow = { id: 1, eventId: "ev1", topic: "t", key: "k", payload: "{}", occurredAtMs: 1 };
  const good = OutboxRelay.headersFor(row, "custody", GOOD_TP);
  assert.equal(good.traceparent, GOOD_TP);
  const bad = OutboxRelay.headersFor(row, "custody", "garbage");
  assert.equal(bad.traceparent, undefined);
  const none = OutboxRelay.headersFor(row, "custody");
  assert.equal(none.traceparent, undefined);
  assert.equal(good.event_id, "ev1");
});

// ---------- PL-06: error → HTTP status vocabulary ----------

test("PL-06: full status vocabulary via exception subclasses", () => {
  assert.equal(new MalformedError("c", "m").httpStatus, 400);
  assert.equal(new BusinessValidationError("c", "m").httpStatus, 422);
  assert.equal(new AuthorizationError("c", "m").httpStatus, 403);
  assert.equal(new StateConflictError("c", "m").httpStatus, 409);
  assert.equal(new LockedError("c", "m").httpStatus, 423);
  const rl = new RateLimitError("c", "m", 30);
  assert.equal(rl.httpStatus, 429);
  assert.equal(rl.headers()["retry-after"], "30");
  assert.equal(rl.toProblem().retryAfter, 30);
});

test("PL-06: category → status map (EF-API-3)", () => {
  assert.equal(statusForCategory("malformed"), HttpStatus.BAD_REQUEST);
  assert.equal(statusForCategory("validation"), HttpStatus.UNPROCESSABLE);
  assert.equal(statusForCategory("four_eyes"), HttpStatus.FORBIDDEN);
  assert.equal(statusForCategory("authz"), HttpStatus.FORBIDDEN);
  assert.equal(statusForCategory("state"), HttpStatus.CONFLICT);
  assert.equal(statusForCategory("idempotency"), HttpStatus.CONFLICT);
  assert.equal(statusForCategory("locked"), HttpStatus.LOCKED);
  assert.equal(statusForCategory("fence"), HttpStatus.LOCKED);
  assert.equal(statusForCategory("rate_limit"), HttpStatus.TOO_MANY_REQUESTS);
  assert.equal(statusForCategory("async"), HttpStatus.ACCEPTED);
  assert.equal(statusForCategory("unavailable"), HttpStatus.SERVICE_UNAVAILABLE);
  assert.equal(statusForCategory("who_knows"), 500);
  // the map covers every canon category exactly
  assert.equal(Object.keys(CATEGORY_STATUS).length, 11);
});

// ---------- PL-08: OpenAPI version pinned to 3.1.0 ----------

test("PL-08: apidocs OpenAPI version is 3.1.0", () => {
  assert.equal(OPENAPI_VERSION, "3.1.0");
});
