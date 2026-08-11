import { test } from "node:test";
import assert from "node:assert/strict";
import { stringifyWithBigInt, RawJson } from "../src/domain/json.js";

// CC-CONS-03 regression: money must survive on the wire as an exact integer literal, never a
// float64 downcast. 13510798882111491 = 4503599627370497 (safe) x 3 — an ODD value between 2^53 and
// 2^54, so `Number(bigint)` would round it to the nearest even (…492). The serializer must keep …491.
const CORRUPTIBLE = 13510798882111491n; // > 2^53, odd → not float64-representable
assert.notEqual(Number(CORRUPTIBLE).toString(), CORRUPTIBLE.toString()); // guard: value IS lossy via Number

test("bigint > 2^53 renders as an exact integer literal (not a float, not a string)", () => {
  const out = stringifyWithBigInt({ amountPoisha: CORRUPTIBLE });
  assert.equal(out, '{"amountPoisha":13510798882111491}');
  // Round-trips exactly through a lossless parser (BigInt reviver stand-in for Java long / Python int).
  assert.equal(/"amountPoisha":(\d+)/.exec(out)![1], "13510798882111491");
});

test("does NOT quote the integer (would break long/int consumers)", () => {
  const out = stringifyWithBigInt({ p: 100n });
  assert.equal(out, '{"p":100}');
  assert.ok(!out.includes('"100"'));
});

test("nested + array bigints all render losslessly", () => {
  const out = stringifyWithBigInt({
    totalAmountPoisha: CORRUPTIBLE,
    items: [{ unitPricePoisha: 4503599627370497n, quantity: 3n }],
  });
  assert.equal(
    out,
    '{"totalAmountPoisha":13510798882111491,"items":[{"unitPricePoisha":4503599627370497,"quantity":3}]}',
  );
});

test("negative and zero bigints render correctly", () => {
  assert.equal(stringifyWithBigInt({ a: -5n, b: 0n }), '{"a":-5,"b":0}');
});

test("non-bigint fields are untouched; ASCII strings never collide with the sentinel", () => {
  const out = stringifyWithBigInt({ ord: "ORD-abc", reason: "buyer changed mind", n: 42n });
  assert.equal(out, '{"ord":"ORD-abc","reason":"buyer changed mind","n":42}');
});

test("int64-max poisha survives (platform money bound)", () => {
  const out = stringifyWithBigInt({ amountPoisha: 9223372036854775807n });
  assert.equal(out, '{"amountPoisha":9223372036854775807}');
});

test("RawJson replays a stored body verbatim (idempotency cache, >2^53 safe)", () => {
  // The idem cache stores exact bytes; on replay it wraps them in RawJson so no lossy re-parse occurs.
  const stored = '{"ord":"ORD-1","totalAmountPoisha":13510798882111491}';
  const out = stringifyWithBigInt({ success: true, data: new RawJson(stored), error: null, meta: { replayed: true } });
  assert.equal(
    out,
    '{"success":true,"data":{"ord":"ORD-1","totalAmountPoisha":13510798882111491},"error":null,"meta":{"replayed":true}}',
  );
});

test("RawJson content with $ characters splices safely (no replacement-pattern interpretation)", () => {
  const out = stringifyWithBigInt({ data: new RawJson('{"note":"$1 $& $$ done","n":5}') });
  assert.equal(out, '{"data":{"note":"$1 $& $$ done","n":5}}');
});
