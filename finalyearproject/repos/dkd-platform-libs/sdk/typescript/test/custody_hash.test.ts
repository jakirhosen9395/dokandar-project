// Cross-language CustodyHash gate (TypeScript side) — asserts the shared golden fixture.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { canonical, eventHash, verifyEvent } from "../src/custody_hash.js";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = JSON.parse(
  readFileSync(join(here, "..", "..", "testvectors", "custodyhash_vectors.json"), "utf8"),
);

test("canonical + digest match the shared fixture", () => {
  for (const v of fixture.vectors) {
    const fields: Record<string, unknown> = { ...v.fields };
    delete fields.eventHash;
    assert.equal(canonical(fields as any), v.canonical, `${v.name} canonical`);
    assert.equal(eventHash(v.fields), v.digest, `${v.name} digest`);
  }
});

test("TV-01 known digest", () => {
  const tv01 = fixture.vectors.find((v: any) => v.name === "TV-01-genesis");
  assert.equal(tv01.digest, "ac543fecee75695fb2b1922ea9e0830f4bddb6ef1ad17e80f278d6171cbe0597");
});

test("eventHash excludes eventHash", () => {
  assert.equal(
    eventHash({ ppid: "PP-1", previousHash: "", eventHash: "f".repeat(64) }),
    eventHash({ ppid: "PP-1", previousHash: "" }),
  );
});

test("int64 > 2^53 must be bigint (money/quantity precision)", () => {
  // A bigint beyond the JS safe-integer range serializes exactly; a number > 2^53 throws
  // (it cannot faithfully carry an int64 — the CC-CONS-03 hazard, forced to bigint here).
  assert.equal(canonical({ q: 9_007_199_254_740_993n }), '{"q":9007199254740993}');
  assert.throws(() => canonical({ q: 2 ** 54 }));
});

test("verifyEvent roundtrip", () => {
  const fields = { ppid: "PP-1", quantity: 5, previousHash: "" };
  assert.equal(verifyEvent({ ...fields, eventHash: eventHash(fields) }), true);
  assert.equal(verifyEvent({ ...fields, eventHash: "0".repeat(64) }), false);
});
