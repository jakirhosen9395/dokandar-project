// /v1/b2c REST surface (context-prefixed like the rest of the fleet; the gateway maps
// public /v1/orders here later). All writes require Idempotency-Key.
import { Router, requireIdemKey, type ReqCtx } from "./router.js";
import { IdemCommands } from "../app/idem.js";
import { OrderService } from "../app/orders.js";
import { OrderStore } from "../store/orders.js";
import type { PgDb } from "../persistence/pg.js";
import { ApiError } from "./router.js";
import { isDid, isGpid } from "../domain/ids.js";

export function buildRouter(db: PgDb, orders: OrderService, store: OrderStore, idem: IdemCommands): Router {
  const r = new Router();

  r.on("POST", "/v1/b2c/orders", async (ctx) => {
    const key = requireIdemKey(ctx);
    // outbound HTTP (eligibility/catalog/reserves) runs in prepare — BEFORE the tx opens
    let prep: Awaited<ReturnType<OrderService["preparePlace"]>> | undefined;
    const out = await idem.run(key, "POST /v1/b2c/orders", ctx.body, 201,
      (tx) => {
        if (!prep) throw new ApiError(500, "dokandar.b2c.internal.prepare_missing", "prepare did not run");
        return orders.commitPlace(tx, prep);
      },
      async () => { prep = await orders.preparePlace(ctx.body, key); });
    return { status: out.status, data: out.data, meta: { replayed: out.replayed } };
  });

  r.on("POST", "/v1/b2c/orders/:ord/cancel", async (ctx) => {
    const out = await cmd(ctx, idem, `POST /v1/b2c/orders/${ctx.params["ord"]}/cancel`,
      (tx) => orders.cancel(tx, ctx.params["ord"],
        String(ctx.body["reason"] ?? ""), String(ctx.body["cancelledBy"] ?? "buyer")));
    if (!out.meta || (out.meta as { replayed?: boolean }).replayed !== true)
      await orders.settleReservations(ctx.params["ord"], "release"); // awaited post-commit
    return out;
  });

  r.on("POST", "/v1/b2c/orders/:ord/start-processing", async (ctx) => cmd(ctx, idem,
    `POST /v1/b2c/orders/${ctx.params["ord"]}/start-processing`,
    (tx) => orders.startProcessing(tx, ctx.params["ord"])));

  r.on("POST", "/v1/b2c/orders/:ord/ship", async (ctx) => cmd(ctx, idem,
    `POST /v1/b2c/orders/${ctx.params["ord"]}/ship`,
    (tx) => orders.ship(tx, ctx.params["ord"], String(ctx.body["shipmentId"] ?? ""))));

  r.on("POST", "/v1/b2c/orders/:ord/deliver", async (ctx) => {
    const out = await cmd(ctx, idem, `POST /v1/b2c/orders/${ctx.params["ord"]}/deliver`,
      (tx) => orders.deliver(tx, ctx.params["ord"],
        typeof ctx.body["deliveredAt"] === "number" ? (ctx.body["deliveredAt"] as number) : undefined));
    if (!out.meta || (out.meta as { replayed?: boolean }).replayed !== true)
      await orders.settleReservations(ctx.params["ord"], "confirm"); // awaited post-commit
    return out;
  });

  r.on("GET", "/v1/b2c/orders/:ord", async (ctx) => ({ data: await orders.get(ctx.params["ord"]) }));

  // Internal seam for Logistics — the only reader of the delivery address (FR-MKT-004).
  r.on("GET", "/internal/orders/:ord", async (ctx) => ({ data: await orders.internalOrder(ctx.params["ord"]) }));

  r.on("POST", "/v1/b2c/cart/items", async (ctx) => {
    const key = requireIdemKey(ctx);
    const did = ctx.body["did"];
    const gpid = ctx.body["gpid"];
    const qty = ctx.body["quantity"];
    const channel = typeof ctx.body["channel"] === "string" && ctx.body["channel"] !== ""
      ? String(ctx.body["channel"]) : "app";
    if (!isDid(did)) throw new ApiError(400, "dokandar.b2c.cart.invalid_did", "did is required");
    if (!isGpid(gpid)) throw new ApiError(400, "dokandar.b2c.cart.invalid_gpid", "gpid is required");
    if (typeof qty !== "number" || !Number.isInteger(qty) || qty <= 0)
      throw new ApiError(400, "dokandar.b2c.cart.invalid_quantity", "quantity must be a positive integer");
    const out = await idem.run(key, "POST /v1/b2c/cart/items", ctx.body, 201, async (tx) => {
      const cartId = await store.addCartLine(tx, did, channel, gpid, BigInt(qty), Date.now());
      return { cartId, gpid, quantity: qty, channel };
    });
    return { status: out.status, data: out.data, meta: { replayed: out.replayed } };
  });

  r.on("GET", "/v1/b2c/cart", async (ctx) => {
    const did = ctx.query.get("did") ?? "";
    const channel = ctx.query.get("channel") ?? "app";
    if (!isDid(did)) throw new ApiError(400, "dokandar.b2c.cart.invalid_did", "did query param required");
    const cart = await store.cart(did, channel);
    return { data: cart ?? { cartId: null, lines: [] } };
  });

  // B2C-13: verified-purchase reviews — a review requires the order DELIVERED and the reviewer to
  // be the order's buyer. GET is public per product (gpid). TCB-ceiling pricing stays future-wave.
  r.on("POST", "/v1/b2c/orders/:ord/review", async (ctx) => {
    const ord = ctx.params["ord"];
    const buyerDid = String(ctx.body["buyerDid"] ?? "");
    const gpid = String(ctx.body["gpid"] ?? "");
    const rating = Number(ctx.body["rating"]);
    const body = String(ctx.body["body"] ?? "");
    if (!isDid(buyerDid)) throw new ApiError(422, "dokandar.b2c.review.buyer", "a valid buyerDid is required");
    if (!isGpid(gpid)) throw new ApiError(422, "dokandar.b2c.review.gpid", "a valid gpid is required");
    if (!Number.isInteger(rating) || rating < 1 || rating > 5) throw new ApiError(422, "dokandar.b2c.review.rating", "rating must be an integer 1..5");
    const order = await store.find(ord);
    if (!order) throw new ApiError(404, "dokandar.b2c.review.order_not_found", "order not found");
    if (order.status !== "DELIVERED") throw new ApiError(409, "dokandar.b2c.review.not_delivered", "only a DELIVERED order can be reviewed (verified purchase)");
    if (order.buyerDid !== buyerDid) throw new ApiError(403, "dokandar.b2c.review.not_buyer", "only the order's buyer may review it");
    const added = await store.addReview(ord, buyerDid, gpid, rating, body, Date.now());
    return { status: added ? 201 : 409, data: { ord, gpid, reviewed: added } };
  });

  r.on("GET", "/v1/b2c/products/:gpid/reviews", async (ctx) => {
    const reviews = await store.reviewsByGpid(ctx.params["gpid"], 50);
    return { status: 200, data: { gpid: ctx.params["gpid"], reviews } };
  });

  return r;
}

async function cmd(ctx: ReqCtx, idem: IdemCommands, endpoint: string,
                   action: Parameters<IdemCommands["run"]>[4]) {
  const key = requireIdemKey(ctx);
  const out = await idem.run(key, endpoint, ctx.body, 200, action);
  return { status: out.status, data: out.data, meta: { replayed: out.replayed } };
}
