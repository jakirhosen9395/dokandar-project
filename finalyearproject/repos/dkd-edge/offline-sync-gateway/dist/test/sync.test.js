import { test } from "node:test";
import assert from "node:assert/strict";
import { replayBatch, isAllowed } from "../src/sync.js";
const okForward = (seen) => async (op) => { seen.push(op); return { status: 201, body: { data: { ord: `ORD-${op.opId}` } } }; };
test("allow-list permits write paths, rejects others", () => {
    assert.ok(isAllowed("/v1/b2c/orders"));
    assert.ok(isAllowed("/v1/parties"));
    assert.ok(!isAllowed("/internal/orders/x"));
    assert.ok(!isAllowed("/v1/analytics/shortages"));
});
test("replays ops in order and returns a per-op verdict", async () => {
    const seen = [];
    const ops = [
        { opId: "a", idempotencyKey: "k-a", method: "POST", path: "/v1/parties", body: {} },
        { opId: "b", idempotencyKey: "k-b", method: "POST", path: "/v1/b2c/orders", body: {} },
    ];
    const results = await replayBatch(ops, okForward(seen));
    assert.deepEqual(seen.map((o) => o.opId), ["a", "b"]);
    assert.equal(results.length, 2);
    assert.ok(results.every((r) => r.ok && r.status === 201));
});
test("HLC timestamps drive causal order regardless of submission order", async () => {
    const seen = [];
    const ops = [
        { opId: "late", idempotencyKey: "k1", method: "POST", path: "/v1/parties", hlc: "2024-01-01T00:00:02Z" },
        { opId: "early", idempotencyKey: "k2", method: "POST", path: "/v1/parties", hlc: "2024-01-01T00:00:01Z" },
    ];
    await replayBatch(ops, okForward(seen));
    assert.deepEqual(seen.map((o) => o.opId), ["early", "late"]);
});
test("a disallowed path is rejected 403 but does NOT abort the rest of the batch", async () => {
    const seen = [];
    const ops = [
        { opId: "bad", idempotencyKey: "k1", method: "POST", path: "/v1/analytics/x" },
        { opId: "good", idempotencyKey: "k2", method: "POST", path: "/v1/parties" },
    ];
    const results = await replayBatch(ops, okForward(seen));
    assert.equal(results.find((r) => r.opId === "bad")?.status, 403);
    assert.equal(results.find((r) => r.opId === "good")?.ok, true);
    assert.deepEqual(seen.map((o) => o.opId), ["good"]); // only the allowed op forwarded
});
test("missing required fields → 400 per-op, batch continues", async () => {
    const results = await replayBatch([{ opId: "x", idempotencyKey: "", method: "POST", path: "/v1/parties" }], okForward([]));
    assert.equal(results[0]?.status, 400);
});
