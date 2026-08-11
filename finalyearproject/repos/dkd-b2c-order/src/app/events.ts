// b2c Published-Language events into the transactional outbox. Topic names come from the
// vendored SDK registry (producer must be context 6 — R6); payloads carry IDs only, never
// PII (deliveryAddress stays in the DB, FR-MKT-004).
import { KafkaTopics as TOPICS, topicMeta } from "@dokandar/platform-sdk";
import type { PgTx } from "../persistence/pg.js";
import { OutboxStore } from "../store/spine.js";
import { newEventId } from "../domain/ids.js";
import type { OrderItem } from "../domain/order.js";
import { stringifyWithBigInt } from "../domain/json.js";

const B2C_CONTEXT = 6;

export class EventFactory {
  constructor(private readonly outbox: OutboxStore) {}

  async orderPlaced(tx: PgTx, ord: string, buyerDid: string, sellerDid: string,
                    items: OrderItem[], totalAmountPoisha: bigint, now: number): Promise<void> {
    await this.emit(tx, TOPICS.B2C_ORDER_ORDER_PLACED_V1, ord, {
      ord, buyerDid, sellerDid,
      items: items.map((it) => ({
        lineId: it.lineId, gpid: it.gpid, ppid: it.ppid ?? undefined,
        quantity: it.quantity, unit: it.unit,
        unitPricePoisha: it.unitPricePoisha,
      })),
      totalAmountPoisha,
      // finance's consumer resolves the escrow amount from amountPoisha-family fields
      amountPoisha: totalAmountPoisha,
      placedAt: now,
    }, now);
  }

  async paymentConfirmed(tx: PgTx, ord: string, escrowId: string, now: number): Promise<void> {
    await this.emit(tx, TOPICS.B2C_ORDER_PAYMENT_CONFIRMED_V1, ord,
      { ord, escrowId, confirmedAt: now }, now);
  }

  async processingStarted(tx: PgTx, ord: string, sellerDid: string, now: number): Promise<void> {
    await this.emit(tx, TOPICS.B2C_ORDER_ORDER_PROCESSING_STARTED_V1, ord,
      { ord, sellerDid, startedAt: now }, now);
  }

  async orderShipped(tx: PgTx, ord: string, shipmentId: string, now: number): Promise<void> {
    await this.emit(tx, TOPICS.B2C_ORDER_ORDER_SHIPPED_V1, ord,
      { ord, shipmentId, shippedAt: now }, now);
  }

  async orderDelivered(tx: PgTx, ord: string, deliveredAt: number, now: number): Promise<void> {
    await this.emit(tx, TOPICS.B2C_ORDER_ORDER_DELIVERED_V1, ord,
      { ord, orderId: ord, deliveredAt }, now);
  }

  async orderCancelled(tx: PgTx, ord: string, reason: string, cancelledBy: string, now: number): Promise<void> {
    await this.emit(tx, TOPICS.B2C_ORDER_ORDER_CANCELLED_V1, ord,
      { ord, orderId: ord, reason, cancelledAt: now, cancelledBy }, now);
  }

  async orderRefunded(tx: PgTx, ord: string, refundAmountPoisha: bigint, now: number): Promise<void> {
    await this.emit(tx, TOPICS.B2C_ORDER_ORDER_REFUNDED_V1, ord,
      { ord, refundAmountPoisha, refundedAt: now }, now);
  }

  private async emit(tx: PgTx, topic: string, key: string,
                     fields: Record<string, unknown>, now: number): Promise<void> {
    if (topicMeta(topic).producer !== B2C_CONTEXT)
      throw new Error(`R6 violation: b2c may not produce ${topic}`);
    const eventId = newEventId();
    // stringifyWithBigInt renders poisha as exact integer literals on the Published-Language wire
    // (CC-CONS-03) — never a Number() float64 downcast.
    const payload = stringifyWithBigInt({ eventId, occurredAt: now, ...fields });
    await this.outbox.insert(tx, eventId, topic, key, payload, now);
  }
}
