// OrderService — the B2C order saga owner. PlaceOrder reserves strong-local stock (G2)
// BEFORE the local transaction; payment confirmation and refunds arrive as finance escrow
// facts over the spine (Conformist to Finance — b2c never moves money itself, FR-MKT-001).
import { ApiError, rejectUnknownFields } from "../http/router.js";
import type { PgDb, PgTx } from "../persistence/pg.js";
import { OrderStore } from "../store/orders.js";
import { EventFactory } from "./events.js";
import { InventoryClient, CatalogClient } from "../clients/rest.js";
import type { Logger } from "../obs/logging.js";
import { newOrd } from "../domain/ids.js";
import {
  canTransition, isTerminal, parseItems, requireBuyer, requireSingleSeller,
  totalPoisha, type OrderItem,
} from "../domain/order.js";
import type { OrderRow } from "../store/orders.js";

export interface PreparedOrder {
  ord: string; buyerDid: string; sellerDid: string; total: bigint;
  address: Record<string, unknown>;
  items: OrderItem[];
  reserved: Array<OrderItem & { reservationId: string | null }>;
}

export interface OrderView {
  ord: string; buyerDid: string; sellerDid: string; status: string;
  totalAmountPoisha: bigint; escrowId: string | null; shipmentId: string | null;
  recallFlag: boolean; trackingStatus: string | null; placedAt: number; updatedAt: number;
  items?: Array<Record<string, unknown>>;
}

function view(o: OrderRow, items?: Array<Record<string, unknown>>): OrderView {
  return {
    ord: o.ord, buyerDid: o.buyerDid, sellerDid: o.sellerDid, status: o.status,
    totalAmountPoisha: o.totalAmountPoisha, escrowId: o.escrowId,
    shipmentId: o.shipmentId, recallFlag: o.recallFlag, trackingStatus: o.trackingStatus,
    placedAt: o.placedAt, updatedAt: o.updatedAt, items,
  };
}

export class OrderService {
  constructor(
    private readonly db: PgDb,
    private readonly store: OrderStore,
    private readonly events: EventFactory,
    private readonly inventory: InventoryClient,
    private readonly catalog: CatalogClient,
    private readonly log: Logger,
  ) {}

  /**
   * PlaceOrder phase 1 (NO transaction — reviewer HIGH: outbound HTTP must never pin a
   * pool connection): validate -> eligibility -> R7 catalog conformance -> G2 reserve per
   * line, compensated on any failure. Reservation idem keys derive from the command key,
   * so a retry after a lost idem race converges on the same holds.
   */
  async preparePlace(body: Record<string, unknown>, idemKey: string): Promise<PreparedOrder> {
    // B2C-12 / EF-API-10: reject any field outside the order-placement contract.
    rejectUnknownFields(body, ["buyerDid", "sellerDid", "items", "deliveryAddress", "channel"]);
    const buyerDid = requireBuyer(body["buyerDid"]);
    const sellerDid = String(body["sellerDid"] ?? "");
    const rawItems = Array.isArray(body["items"]) ? (body["items"] as Array<Record<string, unknown>>) : [];
    requireSingleSeller(sellerDid, rawItems);
    if (buyerDid === sellerDid)
      throw new ApiError(400, "dokandar.b2c.order.buyer_is_seller", "buyer and seller must differ");
    const items = parseItems(rawItems);
    const address = body["deliveryAddress"];
    if (typeof address !== "object" || address === null || Array.isArray(address))
      throw new ApiError(400, "dokandar.b2c.order.address_required", "deliveryAddress object is required");
    await this.requireEligible(buyerDid, "buyer");
    await this.requireEligible(sellerDid, "seller");
    const total = totalPoisha(items);
    for (const gpid of new Set(items.map((i) => i.gpid))) await this.catalog.requirePublished(gpid);
    const reserved: Array<OrderItem & { reservationId: string | null }> = [];
    try {
      for (const it of items) {
        const resId = await this.inventory.reserve(`${idemKey}:${it.lineId}`, it.gpid, sellerDid, it.quantity);
        reserved.push({ ...it, reservationId: resId });
      }
    } catch (e) {
      await this.releaseReservations(reserved.map((r) => r.reservationId));
      throw e;
    }
    return { ord: newOrd(), buyerDid, sellerDid, total,
      address: address as Record<string, unknown>, items, reserved };
  }

  /** PlaceOrder phase 2 (tx-only, no I/O beyond the DB): insert + OrderPlaced atomically. */
  async commitPlace(tx: PgTx, prep: PreparedOrder): Promise<OrderView> {
    const now = Date.now();
    try {
      await this.store.insertOrder(tx, prep.ord, prep.buyerDid, prep.sellerDid, prep.total,
        prep.address, prep.reserved, now);
      await this.events.orderPlaced(tx, prep.ord, prep.buyerDid, prep.sellerDid, prep.items, prep.total, now);
    } catch (e) {
      await this.releaseReservations(prep.reserved.map((r) => r.reservationId));
      throw e;
    }
    return view({
      ord: prep.ord, buyerDid: prep.buyerDid, sellerDid: prep.sellerDid, status: "PENDING_PAYMENT",
      totalAmountPoisha: prep.total, escrowId: null, shipmentId: null, recallFlag: false,
      trackingStatus: null, reason: null, placedAt: now, updatedAt: now, deliveredAt: null,
    });
  }

  async cancel(tx: PgTx, ord: string, reason: string, cancelledBy: string): Promise<OrderView> {
    const now = Date.now();
    const row = await this.requireLocked(tx, ord);
    if (!canTransition(row.status, "CANCELLED"))
      throw new ApiError(409, "dokandar.b2c.order.not_cancellable",
        `order is ${row.status} — cancellation window closed (FR-MKT-084)`);
    this.mustTransition(await this.store.transition(tx, ord, row.status, "CANCELLED",
      { reason: reason || "UNSPECIFIED", cancelledBy: cancelledBy || "buyer" }, now), ord, "CANCELLED");
    await this.events.orderCancelled(tx, ord, reason || "UNSPECIFIED", cancelledBy || "buyer", now);
    // reservations are settled by the caller AFTER this tx commits (reviewer HIGH)
    return this.freshView(tx, ord);
  }

  async startProcessing(tx: PgTx, ord: string): Promise<OrderView> {
    const now = Date.now();
    const row = await this.requireLocked(tx, ord);
    this.requireStep(row, "PROCESSING", "start-processing");
    this.mustTransition(await this.store.transition(tx, ord, row.status, "PROCESSING", {}, now), ord, "PROCESSING");
    await this.events.processingStarted(tx, ord, row.sellerDid, now);
    return this.freshView(tx, ord);
  }

  async ship(tx: PgTx, ord: string, shipmentId: string): Promise<OrderView> {
    const now = Date.now();
    const row = await this.requireLocked(tx, ord);
    this.requireStep(row, "SHIPPED", "ship");
    this.mustTransition(await this.store.transition(tx, ord, row.status, "SHIPPED", { shipmentId }, now), ord, "SHIPPED");
    await this.events.orderShipped(tx, ord, shipmentId || row.shipmentId || "SHP-UNSPECIFIED", now);
    return this.freshView(tx, ord);
  }

  async deliver(tx: PgTx, ord: string, deliveredAt?: number): Promise<OrderView> {
    const now = Date.now();
    const row = await this.requireLocked(tx, ord);
    this.requireStep(row, "DELIVERED", "deliver");
    const at = deliveredAt ?? now;
    this.mustTransition(await this.store.transition(tx, ord, row.status, "DELIVERED", { deliveredAt: at }, now), ord, "DELIVERED");
    await this.events.orderDelivered(tx, ord, at, now);
    // reservations are settled by the caller AFTER this tx commits (reviewer HIGH)
    return this.freshView(tx, ord);
  }

  async get(ord: string): Promise<OrderView> {
    const row = await this.store.find(ord);
    if (!row) throw new ApiError(404, "dokandar.b2c.order.not_found", "order not found");
    const lines = await this.store.lines(ord);
    return view(row, lines.map((l) => ({
      lineId: l.lineId, gpid: l.gpid, ppid: l.ppid ?? undefined,
      quantity: l.quantity, unit: l.unit,
      unitPricePoisha: l.unitPricePoisha, reservationId: l.reservationId ?? undefined,
    })));
  }

  /** Internal seam for Logistics (R7 checklist): the ONLY reader of the delivery address. */
  async internalOrder(ord: string): Promise<Record<string, unknown>> {
    const row = await this.store.find(ord);
    if (!row) throw new ApiError(404, "dokandar.b2c.order.not_found", "order not found");
    const address = await this.store.deliveryAddress(ord);
    return { ord: row.ord, sellerDid: row.sellerDid, buyerDid: row.buyerDid,
             status: row.status, deliveryAddress: address };
  }

  // ---- spine event handlers (called inside the listener's inbox transaction) ----

  /** finance EscrowCreated {referenceType:ORDER, referenceId:ord} -> ConfirmPayment. */
  async onEscrowCreated(tx: PgTx, esc: string, ord: string): Promise<void> {
    const row = await this.store.lock(tx, ord);
    if (!row) { this.log.info("EscrowCreated for unknown order — skipped", { ord }); return; }
    if (row.status !== "PENDING_PAYMENT") {
      this.log.info("EscrowCreated skipped — order not awaiting payment", { ord, status: row.status });
      return;
    }
    const now = Date.now();
    this.mustTransition(await this.store.transition(tx, ord, "PENDING_PAYMENT", "PAYMENT_CONFIRMED", { escrowId: esc }, now), ord, "PAYMENT_CONFIRMED");
    await this.events.paymentConfirmed(tx, ord, esc, now);
  }

  /** finance EscrowReversed {referenceType:ORDER} -> RefundOrder (full reversal = full refund). */
  async onEscrowReversed(tx: PgTx, ord: string): Promise<void> {
    const row = await this.store.lock(tx, ord);
    if (!row) { this.log.info("EscrowReversed for unknown order — skipped", { ord }); return; }
    if (!canTransition(row.status, "REFUNDED")) {
      this.log.info("EscrowReversed skipped — order not refundable", { ord, status: row.status });
      return;
    }
    const now = Date.now();
    this.mustTransition(await this.store.transition(tx, ord, row.status, "REFUNDED",
      { refundAmountPoisha: row.totalAmountPoisha }, now), ord, "REFUNDED");
    await this.events.orderRefunded(tx, ord, row.totalAmountPoisha, now);
  }

  async onShipmentCreated(tx: PgTx, ord: string, shp: string): Promise<void> {
    const row = await this.store.lock(tx, ord);
    if (!row || isTerminal(row.status)) return;
    await this.store.setShipment(tx, ord, shp, Date.now());
  }

  async onDeliveryRecorded(tx: PgTx, ord: string, deliveredAt: number): Promise<void> {
    const row = await this.store.lock(tx, ord);
    if (!row) return;
    if (row.status !== "SHIPPED") {
      this.log.info("DeliveryRecorded skipped — order not SHIPPED", { ord, status: row.status });
      return;
    }
    const now = Date.now();
    this.mustTransition(await this.store.transition(tx, ord, "SHIPPED", "DELIVERED", { deliveredAt }, now), ord, "DELIVERED");
    await this.events.orderDelivered(tx, ord, deliveredAt, now);
    // reservation confirm is settled by the dispatcher AFTER the inbox tx commits
  }

  async onTracking(tx: PgTx, ord: string, status: string): Promise<void> {
    const row = await this.store.lock(tx, ord);
    if (!row) return;
    await this.store.setTracking(tx, ord, status, Date.now());
  }

  async onProductRecalled(tx: PgTx, gpid: string): Promise<void> {
    const n = await this.store.flagRecalled(tx, gpid, Date.now());
    if (n > 0) this.log.info("orders flagged for recall clawback review (SA §9.8)", { gpid, count: n });
  }

  async onEligibility(tx: PgTx, did: string, status: string, kycTier: string | null,
                      occurredAt: number): Promise<void> {
    await this.store.upsertEligibility(tx, did, status, kycTier, occurredAt);
  }

  // ---- helpers ----

  private requireStep(row: OrderRow, to: Parameters<typeof canTransition>[1], action: string): void {
    if (!canTransition(row.status, to))
      throw new ApiError(409, "dokandar.b2c.order.illegal_transition",
        `${action} requires a state that can reach ${to}, but order is ${row.status}`);
  }

  private async requireLocked(tx: PgTx, ord: string): Promise<OrderRow> {
    const row = await this.store.lock(tx, ord);
    if (!row) throw new ApiError(404, "dokandar.b2c.order.not_found", "order not found");
    return row;
  }

  private async freshView(tx: PgTx, ord: string): Promise<OrderView> {
    const row = await this.store.lock(tx, ord);
    if (!row) throw new ApiError(404, "dokandar.b2c.order.not_found", "order not found");
    return view(row);
  }

  /** Buyer/seller must not be SUSPENDED (identity) or HELD (fraud G5). Absent row = allow (dev posture). */
  private async requireEligible(did: string, role: string): Promise<void> {
    const status = await this.store.eligibility(did);
    if (status === "SUSPENDED" || status === "HELD")
      throw new ApiError(409, `dokandar.b2c.order.${role}_not_eligible`,
        `${role} party is ${status} — order placement blocked`);
  }

  /** CAS miss = phantom event risk (reviewer MEDIUM): surface it, never proceed silently. */
  private mustTransition(changed: boolean, ord: string, to: string): void {
    if (!changed)
      throw new ApiError(409, "dokandar.b2c.order.concurrent_transition",
        `order ${ord} changed concurrently while moving to ${to}`);
  }

  /**
   * Post-commit reservation settlement (release|confirm) — AWAITED by callers, errors
   * logged loudly (reviewer HIGH: no fire-and-forget leaks). Inventory transitions are
   * idempotent, so at-least-once retries are safe.
   */
  async settleReservations(ord: string, action: "release" | "confirm"): Promise<void> {
    try {
      const lines = await this.store.lines(ord);
      for (const l of lines) {
        if (!l.reservationId) continue;
        try {
          await this.inventory.transition(l.reservationId, action);
        } catch (e) {
          this.log.error("reservation settlement failed — HELD lot may leak, retry required", {
            ord, resId: l.reservationId, action, err: String(e) });
        }
      }
    } catch (e) {
      this.log.error("reservation settlement lookup failed — HELD lots may leak", {
        ord, action, err: String(e) });
    }
  }

  private async releaseReservations(resIds: Array<string | null>): Promise<void> {
    for (const id of resIds) {
      if (!id) continue;
      try { await this.inventory.transition(id, "release"); }
      catch (e) { this.log.error("reservation release failed — inventory replay-safe", { resId: id, err: String(e) }); }
    }
  }


}
