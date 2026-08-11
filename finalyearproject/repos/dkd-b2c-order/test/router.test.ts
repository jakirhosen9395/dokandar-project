import { test } from "node:test";
import assert from "node:assert/strict";
import { assertIntegerPoisha, ApiError } from "../src/http/router.js";
import { KafkaSpine } from "../src/messaging/kafka.js";

test("integer poisha accepted at any depth", () => {
  assert.doesNotThrow(() => assertIntegerPoisha({
    amountPoisha: 40000,
    lines: [{ unitPricePoisha: 100, qty: 4 }],
    nested: { totalPoisha: 400 },
  }));
});

test("float poisha rejected", () => {
  assert.throws(() => assertIntegerPoisha({ amountPoisha: 47.5 }), (e: unknown) =>
    e instanceof ApiError && e.status === 400 && e.code.includes("money_not_integer"));
});

test("float poisha rejected inside arrays and nesting", () => {
  assert.throws(() => assertIntegerPoisha({ lines: [{ unitPricePoisha: 0.1 }] }), ApiError);
  assert.throws(() => assertIntegerPoisha({ nested: { deep: { xPoisha: 1.5 } } }), ApiError);
});

test("string poisha rejected", () => {
  assert.throws(() => assertIntegerPoisha({ amountPoisha: "40000" as unknown as number }), ApiError);
});

test("unsafe-integer poisha rejected", () => {
  assert.throws(() => assertIntegerPoisha({ amountPoisha: Number.MAX_SAFE_INTEGER + 2 }), (e: unknown) =>
    e instanceof ApiError && e.code.includes("money_unsafe_integer"));
});

test("event id extraction: header wins, payload falls back, synthetic last", () => {
  assert.equal(
    KafkaSpine.eventIdOf("t", 0, "5", { event_id: Buffer.from("hdr-1") }, { eventId: "pay-1" }),
    "hdr-1");
  assert.equal(KafkaSpine.eventIdOf("t", 0, "5", {}, { eventId: "pay-1" }), "pay-1");
  assert.equal(KafkaSpine.eventIdOf("t", 0, "5", {}, { event_id: "snake-1" }), "snake-1");
  assert.equal(KafkaSpine.eventIdOf("t", 2, "7", undefined, {}), "t/2/7");
});
