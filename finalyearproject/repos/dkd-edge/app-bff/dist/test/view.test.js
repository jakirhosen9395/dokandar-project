import { test } from "node:test";
import assert from "node:assert/strict";
import { composeOrderView } from "../src/view.js";
const UP = { b2c: "http://b2c", logistics: "http://log", finance: "http://fin",
    notification: "http://ntf" };
function fakeFetcher(routes) {
    return async (url) => {
        for (const [key, out] of Object.entries(routes)) {
            if (url.includes(key))
                return out;
        }
        return { status: 404, body: null };
    };
}
const order = {
    success: true,
    data: {
        ord: "ORD-1", buyerDid: "did:dokandar:b", shipmentId: "SHP-1", escrowId: "ESC-1",
        status: "DELIVERED",
    },
};
test("composes order + shipment + escrow + notifications", async () => {
    const f = fakeFetcher({
        "/v1/b2c/orders/ORD-1": { status: 200, body: order },
        "/v1/logistics/shipments/SHP-1": { status: 200, body: { data: { shp: "SHP-1", status: "DELIVERED" } } },
        "/v1/finance/escrows/ESC-1": { status: 200, body: { data: { esc: "ESC-1", status: "RELEASED" } } },
        "recipientDid=": { status: 200, body: { data: { items: [{ ntfId: "NTF-1" }] } } },
    });
    const { status, view } = await composeOrderView(f, UP, "ORD-1");
    assert.equal(status, 200);
    assert.equal(view["shipment"].shp, "SHP-1");
    assert.equal(view["escrow"].status, "RELEASED");
    assert.equal(view["notifications"].length, 1);
    assert.deepEqual(view["warnings"], []);
});
test("missing order is a 404", async () => {
    const { status } = await composeOrderView(fakeFetcher({}), UP, "ORD-404");
    assert.equal(status, 404);
});
test("downstream outage degrades to warnings, never a failed page", async () => {
    const f = fakeFetcher({
        "/v1/b2c/orders/ORD-1": { status: 200, body: order },
        "/v1/logistics/shipments/SHP-1": { status: 503, body: null },
        "/v1/finance/escrows/ESC-1": { status: 503, body: null },
        "recipientDid=": { status: 503, body: null },
    });
    const { status, view } = await composeOrderView(f, UP, "ORD-1");
    assert.equal(status, 200);
    assert.equal(view["shipment"], null);
    assert.deepEqual(view["warnings"], ["shipment_unavailable", "escrow_unavailable", "notifications_unavailable"]);
});
test("b2c outage is a 503 problem", async () => {
    const f = fakeFetcher({ "/v1/b2c/orders/ORD-1": { status: 500, body: null } });
    const { status } = await composeOrderView(f, UP, "ORD-1");
    assert.equal(status, 503);
});
