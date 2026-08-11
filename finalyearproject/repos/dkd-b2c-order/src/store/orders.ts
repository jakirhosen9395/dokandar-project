// Order/cart/eligibility rows over Postgres (dkd_b2c). Delivery address stays in the DB —
// it never enters a spine payload (PII rule FR-MKT-004).
import type { PgDb, PgTx, Row } from "../persistence/pg.js";
import type { Migration } from "../persistence/migrate.js";
import type { OrderItem, OrderStatus } from "../domain/order.js";
import { uuid7 } from "../domain/ids.js";

export interface OrderRow {
  ord: string; buyerDid: string; sellerDid: string; status: OrderStatus;
  totalAmountPoisha: bigint; escrowId: string | null; shipmentId: string | null;
  recallFlag: boolean; trackingStatus: string | null; reason: string | null;
  placedAt: number; updatedAt: number; deliveredAt: number | null;
}

export interface LineRow {
  lineId: string; ord: string; gpid: string; ppid: string | null;
  quantity: bigint; unit: string; unitPricePoisha: bigint; reservationId: string | null;
}

function orderOf(r: Row): OrderRow {
  return {
    ord: String(r["ord"]), buyerDid: String(r["buyer_did"]), sellerDid: String(r["seller_did"]),
    status: String(r["status"]) as OrderStatus, totalAmountPoisha: BigInt(String(r["total_amount_poisha"])),
    escrowId: r["escrow_id"] === null ? null : String(r["escrow_id"]),
    shipmentId: r["shipment_id"] === null ? null : String(r["shipment_id"]),
    recallFlag: Boolean(r["recall_flag"]), trackingStatus: r["tracking_status"] === null ? null : String(r["tracking_status"]),
    reason: r["reason"] === null ? null : String(r["reason"]),
    placedAt: Number(r["placed_at"]), updatedAt: Number(r["updated_at"]),
    deliveredAt: r["delivered_at"] === null ? null : Number(r["delivered_at"]),
  };
}

function lineOf(r: Row): LineRow {
  return {
    lineId: String(r["line_id"]), ord: String(r["ord"]), gpid: String(r["gpid"]),
    ppid: r["ppid"] === null ? null : String(r["ppid"]),
    quantity: BigInt(String(r["quantity"])), unit: String(r["unit"]),
    unitPricePoisha: BigInt(String(r["unit_price_poisha"])),
    reservationId: r["reservation_id"] === null ? null : String(r["reservation_id"]),
  };
}

export class OrderStore {
  constructor(private readonly db: PgDb) {}

  async insertOrder(tx: PgTx, ord: string, buyerDid: string, sellerDid: string,
                    totalPoisha: bigint, deliveryAddress: Record<string, unknown>,
                    items: Array<OrderItem & { reservationId: string | null }>, now: number): Promise<void> {
    await tx.exec(
      "INSERT INTO orders(ord, buyer_did, seller_did, status, total_amount_poisha, delivery_address, placed_at, updated_at) " +
      "VALUES ($1,$2,$3,'PENDING_PAYMENT',$4,$5::jsonb,$6,$6)",
      [ord, buyerDid, sellerDid, totalPoisha.toString(), JSON.stringify(deliveryAddress), now]);
    for (const it of items) {
      await tx.exec(
        "INSERT INTO order_lines(line_id, ord, gpid, ppid, quantity, unit, unit_price_poisha, reservation_id) " +
        "VALUES ($1,$2,$3,$4,$5,$6,$7,$8)",
        [it.lineId, ord, it.gpid, it.ppid, it.quantity.toString(), it.unit,
         it.unitPricePoisha.toString(), it.reservationId]);
    }
  }

  async lock(tx: PgTx, ord: string): Promise<OrderRow | null> {
    const rows = await tx.query("SELECT * FROM orders WHERE ord = $1 FOR UPDATE", [ord]);
    return rows.length ? orderOf(rows[0]) : null;
  }

  async lockByEscrow(tx: PgTx, escrowId: string): Promise<OrderRow | null> {
    const rows = await tx.query("SELECT * FROM orders WHERE escrow_id = $1 FOR UPDATE", [escrowId]);
    return rows.length ? orderOf(rows[0]) : null;
  }

  async find(ord: string): Promise<OrderRow | null> {
    const rows = await this.db.query("SELECT * FROM orders WHERE ord = $1", [ord]);
    return rows.length ? orderOf(rows[0]) : null;
  }

  // B2C-13: a verified-purchase review — one per (order, buyer). Caller enforces DELIVERED + buyer match.
  async addReview(ord: string, buyerDid: string, gpid: string, rating: number, body: string, now: number): Promise<boolean> {
    const rows = await this.db.query(
      "INSERT INTO order_review(ord, buyer_did, gpid, rating, body, created_at) VALUES ($1,$2,$3,$4,$5,$6) " +
      "ON CONFLICT (ord, buyer_did) DO NOTHING RETURNING ord", [ord, buyerDid, gpid, rating, body, now]);
    return rows.length > 0;
  }

  async reviewsByGpid(gpid: string, limit: number): Promise<Array<{ ord: string; rating: number; body: string; createdAt: number }>> {
    const capped = limit > 0 && limit <= 200 ? limit : 50;
    const rows = await this.db.query(
      "SELECT ord, rating, body, created_at FROM order_review WHERE gpid = $1 ORDER BY created_at DESC LIMIT $2", [gpid, capped]);
    return rows.map((r) => ({ ord: String(r["ord"]), rating: Number(r["rating"]), body: String(r["body"]), createdAt: Number(r["created_at"]) }));
  }

  async deliveryAddress(ord: string): Promise<Record<string, unknown> | null> {
    const rows = await this.db.query("SELECT delivery_address::text AS a FROM orders WHERE ord = $1", [ord]);
    if (!rows.length) return null;
    try {
      return JSON.parse(String(rows[0]["a"])) as Record<string, unknown>;
    } catch {
      throw new Error(`delivery_address for ${ord} is not valid JSON (data corruption)`);
    }
  }

  async lines(ord: string): Promise<LineRow[]> {
    return (await this.db.query("SELECT * FROM order_lines WHERE ord = $1 ORDER BY line_id", [ord])).map(lineOf);
  }

  /** CAS transition guarded by the current status; extra columns via COALESCE-preserve. */
  async transition(tx: PgTx, ord: string, from: OrderStatus, to: OrderStatus, fields: {
    escrowId?: string; shipmentId?: string; reason?: string; cancelledBy?: string;
    deliveredAt?: number; refundAmountPoisha?: bigint;
  }, now: number): Promise<boolean> {
    const rows = await tx.query(
      "UPDATE orders SET status = $1, escrow_id = COALESCE($2, escrow_id), " +
      "shipment_id = COALESCE($3, shipment_id), reason = COALESCE($4, reason), " +
      "cancelled_by = COALESCE($5, cancelled_by), delivered_at = COALESCE($6, delivered_at), " +
      "refund_amount_poisha = COALESCE($7, refund_amount_poisha), updated_at = $8 " +
      "WHERE ord = $9 AND status = $10 RETURNING ord",
      [to, fields.escrowId ?? null, fields.shipmentId ?? null, fields.reason ?? null,
       fields.cancelledBy ?? null, fields.deliveredAt ?? null,
       fields.refundAmountPoisha === undefined ? null : fields.refundAmountPoisha.toString(),
       now, ord, from]);
    return rows.length === 1;
  }

  async setShipment(tx: PgTx, ord: string, shipmentId: string, now: number): Promise<void> {
    await tx.exec("UPDATE orders SET shipment_id = $1, updated_at = $2 WHERE ord = $3", [shipmentId, now, ord]);
  }

  async setTracking(tx: PgTx, ord: string, status: string, now: number): Promise<void> {
    await tx.exec("UPDATE orders SET tracking_status = $1, updated_at = $2 WHERE ord = $3", [status, now, ord]);
  }

  async flagRecalled(tx: PgTx, gpid: string, now: number): Promise<number> {
    const rows = await tx.query(
      "UPDATE orders SET recall_flag = TRUE, updated_at = $1 WHERE ord IN " +
      "(SELECT DISTINCT ord FROM order_lines WHERE gpid = $2) AND status NOT IN ('REFUNDED') RETURNING ord",
      [now, gpid]);
    return rows.length;
  }

  // --- party eligibility (identity/fraud read-model backing the placement precondition) ---

  /**
   * Event-TIME guarded upsert: eligibility topics (AccountHeld vs AccountHoldReleased,
   * PartySuspended vs PartyReactivated) are separate Kafka topics, so replay order across
   * them is arbitrary — last-write-wins by consumption order would resurrect stale holds.
   * An older event never overwrites a newer state (same class as the provenance H3 fix).
   */
  async upsertEligibility(tx: PgTx, did: string, status: string, kycTier: string | null,
                          occurredAt: number): Promise<void> {
    await tx.exec(
      "INSERT INTO party_eligibility(did, status, kyc_tier, updated_at) VALUES ($1,$2,$3,$4) " +
      "ON CONFLICT (did) DO UPDATE SET status = $2, kyc_tier = COALESCE($3, party_eligibility.kyc_tier), " +
      "updated_at = $4 WHERE party_eligibility.updated_at <= $4",
      [did, status, kycTier, occurredAt]);
  }

  async eligibility(did: string): Promise<string | null> {
    const rows = await this.db.query("SELECT status FROM party_eligibility WHERE did = $1", [did]);
    return rows.length ? String(rows[0]["status"]) : null;
  }

  // --- cart (relational per SA §9.7; one ACTIVE cart per (did, channel)) ---

  async addCartLine(tx: PgTx, did: string, channel: string, gpid: string, quantity: bigint, now: number): Promise<string> {
    const existing = await tx.query(
      "SELECT cart_id FROM carts WHERE did = $1 AND channel = $2 AND status = 'ACTIVE' FOR UPDATE",
      [did, channel]);
    let cartId: string;
    if (existing.length) {
      cartId = String(existing[0]["cart_id"]);
    } else {
      cartId = `cart-${uuid7()}`;
      await tx.exec(
        "INSERT INTO carts(cart_id, did, channel, status, created_at, updated_at) VALUES ($1,$2,$3,'ACTIVE',$4,$4)",
        [cartId, did, channel, now]);
    }
    await tx.exec(
      "INSERT INTO cart_lines(cart_id, gpid, quantity, added_at) VALUES ($1,$2,$3,$4)",
      [cartId, gpid, quantity.toString(), now]);
    return cartId;
  }

  async cart(did: string, channel: string): Promise<{ cartId: string; lines: Array<{ gpid: string; quantity: number }> } | null> {
    const carts = await this.db.query(
      "SELECT cart_id FROM carts WHERE did = $1 AND channel = $2 AND status = 'ACTIVE'", [did, channel]);
    if (!carts.length) return null;
    const cartId = String(carts[0]["cart_id"]);
    const lines = await this.db.query(
      "SELECT gpid, quantity FROM cart_lines WHERE cart_id = $1 ORDER BY id", [cartId]);
    return { cartId, lines: lines.map((l) => ({ gpid: String(l["gpid"]), quantity: Number(l["quantity"]) })) };
  }
}

export const MIGRATIONS: Migration[] = [{
  version: 1,
  description: "b2c core: orders, order_lines, carts, party_eligibility, outbox/inbox/idempotency",
  statements: [
    `CREATE TABLE IF NOT EXISTS orders (
       ord TEXT PRIMARY KEY,
       buyer_did TEXT NOT NULL,
       seller_did TEXT NOT NULL,
       status TEXT NOT NULL CHECK (status IN ('PENDING_PAYMENT','PAYMENT_CONFIRMED','PROCESSING',
         'SHIPPED','DELIVERED','CANCELLED','REFUNDED')),
       total_amount_poisha BIGINT NOT NULL CHECK (total_amount_poisha > 0),
       delivery_address JSONB NOT NULL,
       escrow_id TEXT,
       shipment_id TEXT,
       recall_flag BOOLEAN NOT NULL DEFAULT FALSE,
       tracking_status TEXT,
       reason TEXT,
       cancelled_by TEXT,
       refund_amount_poisha BIGINT,
       placed_at BIGINT NOT NULL,
       updated_at BIGINT NOT NULL,
       delivered_at BIGINT
     )`,
    "CREATE UNIQUE INDEX IF NOT EXISTS orders_escrow_idx ON orders(escrow_id) WHERE escrow_id IS NOT NULL",
    `CREATE TABLE IF NOT EXISTS order_lines (
       line_id TEXT PRIMARY KEY,
       ord TEXT NOT NULL REFERENCES orders(ord),
       gpid TEXT NOT NULL,
       ppid TEXT,
       quantity BIGINT NOT NULL CHECK (quantity > 0),
       unit TEXT NOT NULL,
       unit_price_poisha BIGINT NOT NULL CHECK (unit_price_poisha > 0),
       reservation_id TEXT
     )`,
    "CREATE INDEX IF NOT EXISTS order_lines_ord_idx ON order_lines(ord)",
    "CREATE INDEX IF NOT EXISTS order_lines_gpid_idx ON order_lines(gpid)",
    `CREATE TABLE IF NOT EXISTS carts (
       cart_id TEXT PRIMARY KEY,
       did TEXT NOT NULL,
       channel TEXT NOT NULL,
       status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','ORDERED','ABANDONED')),
       created_at BIGINT NOT NULL,
       updated_at BIGINT NOT NULL
     )`,
    "CREATE UNIQUE INDEX IF NOT EXISTS carts_active_one ON carts(did, channel) WHERE status = 'ACTIVE'",
    `CREATE TABLE IF NOT EXISTS cart_lines (
       id BIGSERIAL PRIMARY KEY,
       cart_id TEXT NOT NULL REFERENCES carts(cart_id),
       gpid TEXT NOT NULL,
       quantity BIGINT NOT NULL CHECK (quantity > 0),
       added_at BIGINT NOT NULL
     )`,
    `CREATE TABLE IF NOT EXISTS party_eligibility (
       did TEXT PRIMARY KEY,
       status TEXT NOT NULL,
       kyc_tier TEXT,
       updated_at BIGINT NOT NULL
     )`,
    `CREATE TABLE IF NOT EXISTS outbox (
       id BIGSERIAL PRIMARY KEY,
       event_id TEXT NOT NULL UNIQUE,
       topic TEXT NOT NULL,
       partition_key TEXT NOT NULL,
       payload JSONB NOT NULL,
       occurred_at BIGINT NOT NULL,
       published_at BIGINT
     )`,
    "CREATE INDEX IF NOT EXISTS outbox_unpublished_idx ON outbox(id) WHERE published_at IS NULL",
    `CREATE TABLE IF NOT EXISTS inbox (
       event_id TEXT PRIMARY KEY,
       topic TEXT NOT NULL,
       processed_at BIGINT NOT NULL
     )`,
    `CREATE TABLE IF NOT EXISTS cmd_idempotency (
       idem_key TEXT NOT NULL,
       endpoint TEXT NOT NULL,
       request_hash TEXT NOT NULL,
       response_status INT NOT NULL,
       response_body JSONB NOT NULL,
       created_at BIGINT NOT NULL,
       PRIMARY KEY (idem_key, endpoint)
     )`,
  ],
}, {
  version: 2,
  description: "B2C-07: DLQ sink for bounded-retry poison quarantine",
  statements: [
    `CREATE TABLE IF NOT EXISTS dlq (
       id BIGSERIAL PRIMARY KEY,
       event_id TEXT NOT NULL,
       topic TEXT NOT NULL,
       partition_key TEXT NOT NULL DEFAULT '',
       payload JSONB NOT NULL,
       error TEXT NOT NULL,
       parked_at BIGINT NOT NULL
     )`,
    "CREATE INDEX IF NOT EXISTS dlq_event_idx ON dlq(event_id)",
  ],
}, {
  version: 3,
  description: "B2C-13: verified-purchase reviews",
  statements: [
    `CREATE TABLE IF NOT EXISTS order_review (
       ord TEXT NOT NULL,
       buyer_did TEXT NOT NULL,
       gpid TEXT NOT NULL,
       rating INT NOT NULL CHECK (rating BETWEEN 1 AND 5),
       body TEXT NOT NULL DEFAULT '',
       created_at BIGINT NOT NULL,
       PRIMARY KEY (ord, buyer_did)
     )`,
    "CREATE INDEX IF NOT EXISTS order_review_gpid_idx ON order_review(gpid, created_at DESC)",
  ],
}];
