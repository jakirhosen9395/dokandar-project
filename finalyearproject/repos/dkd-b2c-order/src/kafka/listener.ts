// b2c's consumer over every registry topic with consumer=6 that this service acts on.
// Inbox dedup happens in the SAME transaction as the state change; business-final skips
// ack; infrastructure errors rethrow (kafkajs redelivers — nothing silently dropped).
import { KafkaTopics as T } from "@dokandar/platform-sdk";
import type { PgDb, PgTx } from "../persistence/pg.js";
import { InboxStore } from "../store/spine.js";
import { OrderService } from "../app/orders.js";
import { ApiError } from "../http/router.js";
import type { Logger } from "../obs/logging.js";
import type { SpineRecord } from "../messaging/kafka.js";
import type { Metrics } from "../obs/metrics.js";

export const CONSUMED_TOPICS: string[] = [
  T.FINANCE_ESCROW_ESCROW_CREATED_V1,
  T.FINANCE_ESCROW_ESCROW_REVERSED_V1,
  T.LOGISTICS_SHIPMENT_SHIPMENT_CREATED_V1,
  T.LOGISTICS_SHIPMENT_RIDER_ASSIGNED_V1,
  T.LOGISTICS_SHIPMENT_DELIVERY_RECORDED_V1,
  T.LOGISTICS_SHIPMENT_SHIPMENT_CANCELLED_V1,
  T.LOGISTICS_SHIPMENT_DELIVERY_FAILED_V1,
  T.CUSTODY_PASSPORT_PRODUCT_RECALLED_V1,
  T.IDENTITY_PARTY_KYCAPPROVED_V1,
  T.IDENTITY_PARTY_KYCTIER_CHANGED_V1,
  T.IDENTITY_PARTY_PARTY_SUSPENDED_V1,
  T.IDENTITY_PARTY_PARTY_REACTIVATED_V1,
  T.FRAUD_ENFORCEMENT_ACCOUNT_HELD_V1,
  T.FRAUD_ENFORCEMENT_ACCOUNT_HOLD_RELEASED_V1,
  T.CATALOG_PRODUCT_PRODUCT_PUBLISHED_V1,
  T.CATALOG_PRODUCT_PRODUCT_DEPRECATED_V1,
  T.CATALOG_PRODUCT_PRODUCT_PRICE_RULE_ADDED_V1,
];

const text = (p: Record<string, unknown>, ...names: string[]): string | null => {
  for (const n of names) {
    const v = p[n];
    if (typeof v === "string" && v !== "") return v;
  }
  return null;
};

/** Event time for ordering guards: payload occurredAt, else now (synthetic/dev events). */
const eventTime = (p: Record<string, unknown>): number =>
  typeof p["occurredAt"] === "number" ? (p["occurredAt"] as number) : Date.now();

// B2C-07: an infra error is retried (kafkajs redelivers on throw) up to MAX_SPINE_RETRIES, then the
// poison record is parked to the DLQ and acked so the partition advances (was: rethrow forever).
const MAX_SPINE_RETRIES = 8;

export class SpineDispatcher {
  private readonly retries = new Map<string, number>();

  constructor(
    private readonly db: PgDb,
    private readonly inbox: InboxStore,
    private readonly orders: OrderService,
    private readonly metrics: Metrics,
    private readonly log: Logger,
  ) {}

  async handle(rec: SpineRecord): Promise<void> {
    try {
      await this.db.withTx(async (tx) => {
        if (!(await this.inbox.tryMark(tx, rec.eventId, rec.topic, Date.now()))) return; // duplicate
        await this.dispatch(rec, tx);
      });
      this.metrics.inc("b2c_spine_processed_total");
      // reservation confirm is settled AFTER the inbox tx commits (awaited, idempotent)
      if (rec.topic === T.LOGISTICS_SHIPMENT_DELIVERY_RECORDED_V1) {
        const ord = text(rec.payload, "referenceId", "orderId", "ord");
        if (ord) await this.orders.settleReservations(ord, "confirm");
      }
    } catch (e) {
      if (e instanceof ApiError && e.status < 500) {
        // a business verdict cannot change on retry: ack and record the skip
        this.log.info("business-final spine skip", { topic: rec.topic, eventId: rec.eventId, err: e.message });
        this.metrics.inc("b2c_spine_skipped_total");
        this.retries.delete(rec.eventId);
        return;
      }
      // B2C-07: bounded retry (kafkajs redelivers on throw), then park to the DLQ and ack (advance).
      const n = (this.retries.get(rec.eventId) ?? 0) + 1;
      this.retries.set(rec.eventId, n);
      if (n < MAX_SPINE_RETRIES) {
        this.log.info("spine handle failed — will replay", { topic: rec.topic, eventId: rec.eventId, attempt: n });
        throw e; // kafkajs redelivers
      }
      try {
        await this.db.query(
          "INSERT INTO dlq(event_id, topic, partition_key, payload, error, parked_at) VALUES ($1,$2,$3,$4,$5,$6)",
          [rec.eventId, rec.topic, rec.key ?? "", JSON.stringify(rec.payload ?? {}),
           String(e instanceof Error ? e.message : e).slice(0, 1000), Date.now()]);
        this.metrics.inc("b2c_spine_dlq_parked_total");
        this.retries.delete(rec.eventId);
        this.log.error("b2c poison spine event PARKED to DLQ after bounded retries — advancing",
          { topic: rec.topic, eventId: rec.eventId });
        return; // acked → partition advances
      } catch (parkErr) {
        this.log.error("DLQ park FAILED — will replay (never drop)",
          { topic: rec.topic, eventId: rec.eventId, err: String(parkErr) });
        throw e; // could not park → keep replaying
      }
    }
  }

  private async dispatch(rec: SpineRecord, tx: PgTx): Promise<void> {
    const p = rec.payload;
    switch (rec.topic) {
      case T.FINANCE_ESCROW_ESCROW_CREATED_V1: {
        if (text(p, "referenceType") !== "ORDER") return;
        const ord = text(p, "referenceId");
        const esc = text(p, "esc", "escrowId");
        if (!ord || !esc) return this.skip(rec, "EscrowCreated without referenceId/esc");
        await this.orders.onEscrowCreated(tx, esc, ord);
        return;
      }
      case T.FINANCE_ESCROW_ESCROW_REVERSED_V1: {
        if (text(p, "referenceType") !== "ORDER") return;
        const ord = text(p, "referenceId");
        if (!ord) return this.skip(rec, "EscrowReversed without referenceId");
        await this.orders.onEscrowReversed(tx, ord);
        return;
      }
      case T.LOGISTICS_SHIPMENT_SHIPMENT_CREATED_V1: {
        const ord = text(p, "referenceId", "orderId", "ord");
        const shp = text(p, "shp", "shipmentId");
        if (!ord || !shp || text(p, "referenceType") === "TRADE") return;
        await this.orders.onShipmentCreated(tx, ord, shp);
        return;
      }
      case T.LOGISTICS_SHIPMENT_DELIVERY_RECORDED_V1: {
        const ord = text(p, "referenceId", "orderId", "ord");
        if (!ord || text(p, "referenceType") === "TRADE") return;
        const at = typeof p["deliveredAt"] === "number" ? (p["deliveredAt"] as number) : Date.now();
        await this.orders.onDeliveryRecorded(tx, ord, at);
        return;
      }
      case T.LOGISTICS_SHIPMENT_RIDER_ASSIGNED_V1:
      case T.LOGISTICS_SHIPMENT_SHIPMENT_CANCELLED_V1:
      case T.LOGISTICS_SHIPMENT_DELIVERY_FAILED_V1: {
        const ord = text(p, "referenceId", "orderId", "ord");
        if (!ord) return;
        await this.orders.onTracking(tx, ord, rec.topic.split(".")[2] /* logistics.shipment.<Event>.v1 -> <Event> */);
        return;
      }
      case T.CUSTODY_PASSPORT_PRODUCT_RECALLED_V1: {
        const gpid = text(p, "gpid");
        if (!gpid) return this.skip(rec, "ProductRecalled without gpid");
        await this.orders.onProductRecalled(tx, gpid);
        return;
      }
      case T.IDENTITY_PARTY_PARTY_SUSPENDED_V1:
        return this.eligibility(tx, p, "SUSPENDED");
      case T.IDENTITY_PARTY_PARTY_REACTIVATED_V1:
        return this.eligibility(tx, p, "ACTIVE");
      case T.IDENTITY_PARTY_KYCAPPROVED_V1:
      case T.IDENTITY_PARTY_KYCTIER_CHANGED_V1: {
        const did = text(p, "did", "partyDid");
        if (!did) return;
        await this.orders.onEligibility(tx, did, "ACTIVE", text(p, "tier", "kycTier", "newTier"), eventTime(p));
        return;
      }
      case T.FRAUD_ENFORCEMENT_ACCOUNT_HELD_V1:
        return this.eligibility(tx, p, "HELD");
      case T.FRAUD_ENFORCEMENT_ACCOUNT_HOLD_RELEASED_V1:
        return this.eligibility(tx, p, "ACTIVE");
      default:
        // catalog listing topics: the read-model lives in catalog-svc/b2c-catalog-read-svc
        // (SA split); placement re-validates via the catalog OHS instead (dev posture).
        this.skip(rec, "read-model topic — served by the catalog OHS in this deployment");
    }
  }

  private async eligibility(tx: PgTx, p: Record<string, unknown>, status: string): Promise<void> {
    const did = text(p, "subjectDid", "did", "partyDid", "targetDid"); // registry payload = subjectDid
    if (!did) return;
    await this.orders.onEligibility(tx, did, status, null, eventTime(p));
  }

  private skip(rec: SpineRecord, why: string): void {
    this.log.info("spine skip", { topic: rec.topic, why });
    this.metrics.inc("b2c_spine_unmapped_total");
  }
}
