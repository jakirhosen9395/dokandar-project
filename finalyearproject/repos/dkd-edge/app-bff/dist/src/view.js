// The consumer order journey view: ONE read composing b2c + logistics + finance +
// notification REST responses (SA §19.2 app-bff role: aggregate views, no writes, no
// stores). Tolerant composition — a missing downstream degrades to null + a warning,
// never a failed page (rural 2G first, FR-MKT-014 spirit).
function dataOf(body) {
    if (typeof body !== "object" || body === null)
        return null;
    const env = body;
    return typeof env.data === "object" && env.data !== null ? env.data : null;
}
export async function composeOrderView(fetcher, up, ord) {
    const warnings = [];
    const orderRes = await fetcher(`${up.b2c}/v1/b2c/orders/${encodeURIComponent(ord)}`);
    if (orderRes.status === 404) {
        return { status: 404, view: { code: "dokandar.edge.not_found.order", ord } };
    }
    if (orderRes.status !== 200) {
        return { status: 503, view: { code: "dokandar.edge.infrastructure.b2c_unavailable", ord } };
    }
    const order = dataOf(orderRes.body);
    if (order === null) {
        return { status: 502, view: { code: "dokandar.edge.infrastructure.bad_envelope", ord } };
    }
    // The three enrichments are independent — fetch them CONCURRENTLY (2G latency budget,
    // FR-MKT-014): worst-case is one timeout, never the sum of three.
    const shipmentId = typeof order["shipmentId"] === "string" ? order["shipmentId"] : "";
    const escrowId = typeof order["escrowId"] === "string" ? order["escrowId"] : "";
    const buyerDid = typeof order["buyerDid"] === "string" ? order["buyerDid"] : "";
    const [shipRes, escRes, ntfRes] = await Promise.all([
        shipmentId === "" ? Promise.resolve(null)
            : fetcher(`${up.logistics}/v1/logistics/shipments/${encodeURIComponent(shipmentId)}`),
        escrowId === "" ? Promise.resolve(null)
            : fetcher(`${up.finance}/v1/finance/escrows/${encodeURIComponent(escrowId)}`),
        buyerDid === "" ? Promise.resolve(null)
            : fetcher(`${up.notification}/v1/notifications?recipientDid=${encodeURIComponent(buyerDid)}`),
    ]);
    let shipment = null;
    if (shipRes !== null) {
        if (shipRes.status === 200)
            shipment = dataOf(shipRes.body);
        else
            warnings.push("shipment_unavailable");
    }
    let escrow = null;
    if (escRes !== null) {
        if (escRes.status === 200)
            escrow = dataOf(escRes.body);
        else
            warnings.push("escrow_unavailable");
    }
    let notifications = [];
    if (ntfRes !== null) {
        const data = ntfRes.status === 200 ? dataOf(ntfRes.body) : null;
        if (data !== null && Array.isArray(data["items"])) {
            notifications = data["items"].slice(0, 10);
        }
        else {
            warnings.push("notifications_unavailable");
        }
    }
    return {
        status: 200,
        view: {
            ord,
            order,
            shipment,
            escrow,
            notifications,
            warnings,
        },
    };
}
