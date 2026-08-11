import { test } from "node:test";
import assert from "node:assert/strict";
import { CONTRACT_VERSION } from "../src/provenance.js";
import { DID, PPID } from "../src/ids.js";
import { Money } from "../src/money.js";
import { TOPIC_META, RabbitQueues } from "../src/topics.js";
import { errorCode, ContextSlug } from "../src/errors.js";

test("provenance", () => { assert.equal(CONTRACT_VERSION, "1.0.0"); });

test("ids typed + validated", () => {
  const d = new DID("did:dokandar:abc");
  assert.equal(d.toString(), "did:dokandar:abc");
  assert.equal(DID.IMMUTABLE, true);
  assert.equal(DID.OWNER_CONTEXT, 1);
  assert.throws(() => new PPID("did:dokandar:x"));
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
