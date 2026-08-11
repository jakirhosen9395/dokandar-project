import { test } from "node:test";
import assert from "node:assert/strict";
import {
  canTransition, isTerminal, parseItems, requireSingleSeller, totalPoisha,
} from "../src/domain/order.js";
import { ApiError } from "../src/http/router.js";
import { uuid7, newOrd } from "../src/domain/ids.js";

test("order state machine follows the DM transitions", () => {
  assert.ok(canTransition("PENDING_PAYMENT", "PAYMENT_CONFIRMED"));
  assert.ok(canTransition("PENDING_PAYMENT", "CANCELLED"));
  assert.ok(!canTransition("PENDING_PAYMENT", "SHIPPED"));
  assert.ok(canTransition("PAYMENT_CONFIRMED", "PROCESSING"));
  assert.ok(canTransition("PAYMENT_CONFIRMED", "SHIPPED"));
  assert.ok(canTransition("SHIPPED", "DELIVERED"));
  assert.ok(canTransition("DELIVERED", "REFUNDED"));
  assert.ok(canTransition("CANCELLED", "REFUNDED"));
  assert.ok(!canTransition("DELIVERED", "CANCELLED"));
  assert.ok(isTerminal("REFUNDED"));
  assert.ok(!isTerminal("SHIPPED"));
});

test("single-seller invariant rejects mixed-seller items", () => {
  const seller = "did:dokandar:0190aaaa-bbbb-7ccc-8ddd-eeeeffff0001";
  assert.doesNotThrow(() => requireSingleSeller(seller, [{ gpid: "GP-x" }, { sellerDid: seller }]));
  assert.throws(() => requireSingleSeller(seller,
    [{ sellerDid: "did:dokandar:0190aaaa-bbbb-7ccc-8ddd-eeeeffff0002" }]),
    (e: unknown) => e instanceof ApiError && e.status === 409 && e.code.includes("multiple_sellers"));
});

test("items parse with integer validation and bigint totals are exact", () => {
  const items = parseItems([
    { gpid: "GP-rice-1", quantity: 3, unitPricePoisha: 12000, unit: "seer" },
    { gpid: "GP-rice-2", quantity: 2, unitPricePoisha: 500 },
  ]);
  assert.equal(items.length, 2);
  assert.equal(totalPoisha(items), 37000n);
  assert.equal(items[0].unit, "seer");
  assert.equal(items[1].unit, "unit");
});

test("items reject empty list, bad gpid, non-positive quantity, float price", () => {
  assert.throws(() => parseItems([]), ApiError);
  assert.throws(() => parseItems([{ gpid: "X", quantity: 1, unitPricePoisha: 1 }]), ApiError);
  assert.throws(() => parseItems([{ gpid: "GP-a", quantity: 0, unitPricePoisha: 1 }]), ApiError);
  assert.throws(() => parseItems([{ gpid: "GP-a", quantity: 1, unitPricePoisha: 10.5 }]), ApiError);
});

test("value-validation surfaces as 422, not 400 (B2C-11 / EF-API-3)", () => {
  // well-formed JSON, semantically-invalid value → 422 Unprocessable
  assert.throws(() => parseItems([{ gpid: "GP-a", quantity: 0, unitPricePoisha: 1 }]),
    (e: unknown) => e instanceof ApiError && e.status === 422);
  assert.throws(() => parseItems([]),
    (e: unknown) => e instanceof ApiError && e.status === 422);
});

test("order total between 2^53 and int64 is now valid and exact (CC-CONS-03)", () => {
  // 4503599627370497 (safe unit price) x 3 = 13510798882111491 — an ODD value > 2^53 that the old
  // 2^53 cap wrongly rejected and that Number() would corrupt. It is well within int64, so valid.
  const items = parseItems([{ gpid: "GP-a", quantity: 3, unitPricePoisha: 4_503_599_627_370_497 }]);
  assert.equal(totalPoisha(items), 13510798882111491n);
});

test("order total beyond the int64 poisha bound is rejected", () => {
  const items = parseItems([{ gpid: "GP-a", quantity: 2000, unitPricePoisha: 9_000_000_000_000_000 }]);
  assert.throws(() => totalPoisha(items), (e: unknown) =>
    e instanceof ApiError && e.code.includes("total_exceeds_bound"));
});

test("uuid7 shape and ORD prefix", () => {
  assert.match(uuid7(), /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.match(newOrd(), /^ORD-[0-9a-f-]{36}$/);
});
