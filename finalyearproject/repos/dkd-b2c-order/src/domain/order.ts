// Order aggregate rules (Domain-Model Context #6; DM vocabulary wins per ADR-016).
// Money is bigint poisha internally; JSON boundaries carry integer numbers (safe-range guarded).
import { ApiError } from "../http/router.js";
import { isDid, isGpid, uuid7 } from "./ids.js";

export type OrderStatus =
  | "PENDING_PAYMENT" | "PAYMENT_CONFIRMED" | "PROCESSING"
  | "SHIPPED" | "DELIVERED" | "CANCELLED" | "REFUNDED";

/** Legal transitions (DM state machine). Terminal: REFUNDED. */
const LEGAL: Record<OrderStatus, readonly OrderStatus[]> = {
  PENDING_PAYMENT: ["PAYMENT_CONFIRMED", "CANCELLED"],
  PAYMENT_CONFIRMED: ["PROCESSING", "SHIPPED", "CANCELLED"],
  PROCESSING: ["SHIPPED", "CANCELLED"],
  SHIPPED: ["DELIVERED", "CANCELLED"],
  DELIVERED: ["REFUNDED"],
  CANCELLED: ["REFUNDED"],
  REFUNDED: [],
};

export function canTransition(from: OrderStatus, to: OrderStatus): boolean {
  return LEGAL[from].includes(to);
}

export function isTerminal(status: OrderStatus): boolean {
  return LEGAL[status].length === 0;
}

export interface OrderItem {
  lineId: string;
  gpid: string;
  ppid: string | null;
  quantity: bigint;
  unit: string;
  unitPricePoisha: bigint;
}

// The wire now carries poisha as exact integer literals (see domain/json.ts), so the platform money
// bound is int64 (DM-TYPE-001 money = int64 poisha; every consumer stores `long`/`int` poisha), NOT
// the old 2^53 JSON-float band-aid that capped legitimate large orders.
const MAX_INT64 = 9223372036854775807n;

/** Parse + validate raw request items; enforces >=1 line, positive integers, GPID shape. */
export function parseItems(raw: unknown): OrderItem[] {
  // EF-API-3 (B2C-11): well-formed request, semantically-invalid VALUES → 422 (unprocessable);
  // only genuinely malformed JSON (readJson) stays 400.
  if (!Array.isArray(raw) || raw.length < 1)
    throw new ApiError(422, "dokandar.b2c.order.items_required", "an order needs at least one item");
  return raw.map((r) => {
    const o = r as Record<string, unknown>;
    if (!isGpid(o["gpid"]))
      throw new ApiError(422, "dokandar.b2c.order.invalid_gpid", "each item needs a GP- gpid");
    const qty = o["quantity"];
    if (typeof qty !== "number" || !Number.isInteger(qty) || qty <= 0)
      throw new ApiError(422, "dokandar.b2c.order.invalid_quantity", "quantity must be a positive integer");
    const price = o["unitPricePoisha"];
    if (typeof price !== "number" || !Number.isInteger(price) || price <= 0)
      throw new ApiError(422, "dokandar.b2c.order.invalid_price", "unitPricePoisha must be a positive integer");
    const ppid = o["ppid"];
    return {
      lineId: uuid7(),
      gpid: o["gpid"] as string,
      ppid: typeof ppid === "string" && ppid.startsWith("PP-") ? ppid : null,
      quantity: BigInt(qty),
      unit: typeof o["unit"] === "string" && o["unit"] !== "" ? (o["unit"] as string) : "unit",
      unitPricePoisha: BigInt(price),
    };
  });
}

/** totalAmountPoisha = sum(unitPricePoisha x quantity), bigint-exact, bounded by int64 poisha. */
export function totalPoisha(items: OrderItem[]): bigint {
  const total = items.reduce((acc, it) => acc + it.unitPricePoisha * it.quantity, 0n);
  if (total > MAX_INT64)
    throw new ApiError(422, "dokandar.b2c.order.total_exceeds_bound",
      "order total exceeds the int64 poisha bound");
  return total;
}

/** Single-seller invariant (DM v1): enforced synchronously at PlaceOrder. */
export function requireSingleSeller(sellerDid: string, items: ReadonlyArray<Record<string, unknown>>): void {
  if (!isDid(sellerDid))
    throw new ApiError(422, "dokandar.b2c.order.invalid_seller", "sellerDid must be a did:dokandar DID");
  for (const it of items) {
    const itemSeller = it["sellerDid"];
    if (itemSeller !== undefined && itemSeller !== sellerDid)
      throw new ApiError(409, "dokandar.b2c.order.multiple_sellers",
        "all order items must belong to the single order seller (DM single-seller invariant)");
  }
}

export function requireBuyer(buyerDid: unknown): string {
  if (!isDid(buyerDid))
    throw new ApiError(422, "dokandar.b2c.order.invalid_buyer", "buyerDid must be a did:dokandar DID");
  return buyerDid;
}

// NOTE: `asMoneyNumber` (a `Number(bigint)` float64 downcast) was removed in CC-CONS-03 — money now
// stays bigint end-to-end and is serialized as an exact integer literal by domain/json.ts on both the
// Kafka wire (app/events.ts) and REST responses (http/router.ts). Do not reintroduce a numeric cast.
