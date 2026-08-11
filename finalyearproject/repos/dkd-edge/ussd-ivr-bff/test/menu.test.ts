import { test } from "node:test";
import assert from "node:assert/strict";
import { step, latestInput, type Deps, type Session } from "../src/menu.js";

const products = [{ gpid: "GP-rice-1", seller: "did:dokandar:seller-1", name: "মিনিকেট চাল" }];

function fakeDeps(placed: string[]): Deps {
  return {
    listProducts: async () => products,
    resolveBuyer: async (phone) => `did:dokandar:buyer-${phone}`,
    placeOrder: async (buyer, seller, gpid, qty) => {
      placed.push(`${buyer}|${seller}|${gpid}|${qty}`);
      return "ORD-USSD-1";
    },
    getOrderStatus: async (ord) => (ord === "ORD-KNOWN" ? "DELIVERED" : null),
  };
}

test("latestInput takes the last *-segment", () => {
  assert.equal(latestInput(""), "");
  assert.equal(latestInput("1"), "1");
  assert.equal(latestInput("1*2*5"), "5");
});

test("full USSD order flow places the SAME b2c order as the app path (R8 parity)", async () => {
  const placed: string[] = [];
  const deps = fakeDeps(placed);
  const sessions = new Map<string, Session>();
  const sid = "sess-1";
  const phone = "+8801700000000";

  let r = await step(sessions, sid, phone, "", deps); // new session
  assert.ok(r.cont && r.message.includes("DOKANDAR"));

  r = await step(sessions, sid, phone, "1", deps); // choose "buy"
  assert.ok(r.cont && r.message.includes("চাল"));

  r = await step(sessions, sid, phone, "1*1", deps); // pick product 1
  assert.ok(r.cont && r.message.includes("পরিমাণ"));

  r = await step(sessions, sid, phone, "1*1*3", deps); // qty 3
  assert.ok(r.cont && r.message.includes("নিশ্চিত"));

  r = await step(sessions, sid, phone, "1*1*3*1", deps); // confirm yes -> place order
  assert.ok(!r.cont, "confirm should END the session");
  assert.ok(r.message.includes("ORD-USSD-1"), "reply carries the order id");

  assert.equal(placed.length, 1);
  assert.equal(placed[0], `did:dokandar:buyer-${phone}|did:dokandar:seller-1|GP-rice-1|3`);
  assert.equal(sessions.size, 0, "session cleared after END");
});

test("order-status flow returns the b2c status", async () => {
  const sessions = new Map<string, Session>();
  const deps = fakeDeps([]);
  await step(sessions, "s2", "+8801711111111", "", deps);
  await step(sessions, "s2", "+8801711111111", "2", deps); // status menu
  const r = await step(sessions, "s2", "+8801711111111", "2*ORD-KNOWN", deps);
  assert.ok(!r.cont && r.message.includes("DELIVERED"));
});

test("every reply stays within the 160-char USSD frame", async () => {
  const sessions = new Map<string, Session>();
  const deps = fakeDeps([]);
  const r1 = await step(sessions, "s3", "+8801722222222", "", deps);
  const r2 = await step(sessions, "s3", "+8801722222222", "9", deps); // bad input
  assert.ok(r1.message.length <= 160 && r2.message.length <= 160);
});
