import { test } from "node:test";
import assert from "node:assert/strict";
import { CONTRACT_VERSION } from "../src/provenance.js";
import { DID, PPID } from "../src/ids.js";
import { Money } from "../src/money.js";
import { TOPIC_META, RabbitQueues } from "../src/topics.js";
import { errorCode, ContextSlug } from "../src/errors.js";

test("provenance", () => { assert.equal(CONTRACT_VERSION, "1.0.0"); });

test("ids typed + validated (PL-04: body must be UUID v7)", () => {
  const V7 = "0190b8e0-8f6a-7c3d-9a2b-1c4d5e6f7a8b";
  const d = new DID("did:dokandar:" + V7);
  assert.equal(d.toString(), "did:dokandar:" + V7);
  assert.equal(DID.IMMUTABLE, true);
  assert.equal(DID.OWNER_CONTEXT, 1);
  // wrong prefix rejected
  assert.throws(() => new PPID("did:dokandar:" + V7));
  // legacy non-UUID body ("abc") now rejected — a v4/garbage body must fail
  assert.throws(() => new DID("did:dokandar:abc"));
});

test("topics: 59 with metadata", () => {
  assert.equal(Object.keys(TOPIC_META).length, 59);
  assert.equal(TOPIC_META["custody.passport.CustodyInitialized.v1"].producer, 3);
  assert.equal(Object.keys(RabbitQueues).length, 10);
});

test("money is bigint int64", () => {
  assert.equal(new Money(5000n).poisha, 5000n);
  assert.throws(() => new Money(50 as unknown as bigint));
});

test("error taxonomy", () => {
  assert.equal(errorCode("finance", "idempotency", "duplicate_key"), "dokandar.finance.idempotency.duplicate_key");
  assert.throws(() => errorCode("frobnicate", "x", "y"));
  assert.equal(ContextSlug.FINANCE, "finance");
});
