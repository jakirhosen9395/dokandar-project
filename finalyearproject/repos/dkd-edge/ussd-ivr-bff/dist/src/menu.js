// ussd-ivr-bff — DOKANDAR edge #35. R8 channel parity: a stateful Bangla USSD menu that drives the
// SAME write APIs as the app path (POST /v1/b2c/orders through the gateway). Feature-phone/2G first.
//
// Every reply is a USSD response: `CON <text>` keeps the session open, `END <text>` terminates.
// Menu text is Bangla and MUST stay <=160 chars (single GSM-7 USSD frame). No PII on the wire beyond
// the caller's own phone (used only to resolve/onboard their DID via Identity).
const con = (m) => ({ cont: true, message: clip(m) });
const end = (m) => ({ cont: false, message: clip(m) });
// USSD single-frame safety: hard-cap at 160 chars so a reply never overflows the GSM-7 frame.
function clip(m) {
    return m.length <= 160 ? m : m.slice(0, 157) + "...";
}
const WELCOME = "স্বাগতম DOKANDAR\n1) পণ্য কিনুন\n2) অর্ডার দেখুন";
/** Latest user input = the last '*'-separated segment of the accumulated USSD text. */
export function latestInput(text) {
    if (!text)
        return "";
    const parts = text.split("*");
    return (parts[parts.length - 1] ?? "").trim();
}
/**
 * Stateful USSD FSM. `sessions` is the per-sessionId store (in-memory in the BFF; a durable store is
 * the offline-sync concern). Returns the reply and mutates/creates the session.
 */
export async function step(sessions, sessionId, phoneNumber, text, deps) {
    const input = latestInput(text);
    let s = sessions.get(sessionId);
    // New session (no prior state, empty text) -> the root menu.
    if (s === undefined || text === "") {
        s = { step: "MENU" };
        sessions.set(sessionId, s);
        if (text === "")
            return con(WELCOME);
    }
    switch (s.step) {
        case "MENU": {
            if (input === "1") {
                const products = await deps.listProducts();
                if (products.length === 0)
                    return end("এই মুহূর্তে কোনো পণ্য নেই। পরে চেষ্টা করুন।");
                s.products = products;
                s.step = "PICK";
                return con("পণ্য বেছে নিন:\n" + numbered(products));
            }
            if (input === "2") {
                s.step = "STATUS";
                return con("অর্ডার আইডি লিখুন (ORD-...):");
            }
            return con("ভুল ইনপুট।\n" + WELCOME);
        }
        case "PICK": {
            const idx = Number(input) - 1;
            const p = s.products?.[idx];
            if (!p)
                return con("ভুল নম্বর। আবার বেছে নিন:\n" + numbered(s.products ?? []));
            s.gpid = p.gpid;
            s.seller = p.seller;
            s.step = "QTY";
            return con(`${p.name}\nপরিমাণ (কেজি) লিখুন:`);
        }
        case "QTY": {
            const qty = Number(input);
            if (!Number.isInteger(qty) || qty <= 0)
                return con("পরিমাণ একটি ধনাত্মক সংখ্যা হতে হবে। আবার লিখুন:");
            s.qty = qty;
            s.step = "CONFIRM";
            return con(`নিশ্চিত করুন: ${qty} কেজি\n1) হ্যাঁ\n2) বাতিল`);
        }
        case "CONFIRM": {
            if (input !== "1") {
                sessions.delete(sessionId);
                return end("অর্ডার বাতিল হয়েছে।");
            }
            const buyer = await deps.resolveBuyer(phoneNumber);
            const ord = await deps.placeOrder(buyer, s.seller ?? "", s.gpid ?? "", s.qty ?? 0);
            sessions.delete(sessionId);
            return end(`অর্ডার সফল হয়েছে।\n${ord}`);
        }
        case "STATUS": {
            const status = await deps.getOrderStatus(input);
            sessions.delete(sessionId);
            if (status === null)
                return end("অর্ডার পাওয়া যায়নি।");
            return end(`স্ট্যাটাস: ${status}`);
        }
        default:
            sessions.delete(sessionId);
            return end("সেশন শেষ।");
    }
}
function numbered(products) {
    return products.slice(0, 5).map((p, i) => `${i + 1}) ${p.name}`).join("\n");
}
