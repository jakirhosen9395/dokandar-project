"use client";
import { authedFetch } from "@/lib/auth-client";

// Real COD checkout (verified working end-to-end): build an immutable quote via cart checkout-package,
// then place the order via the Temporal-backed order saga. Both require an Idempotency-Key (forwarded by
// the BFF). No payment provider is needed for cash-on-delivery.
export interface QuoteItem {
  product_id: string;
  variant_id: string;
  quantity: number;
  unit_price_minor: number;
  line_total_minor?: number;
  sale_price_minor?: number | null;
}
export interface SubOrder {
  shop_id: string;
  items: QuoteItem[];
  subtotal_minor?: number;
}
export interface CheckoutQuote {
  checkout_id: string;
  sub_orders: SubOrder[];
  grand_total_minor?: number;
  coupon_applied?: unknown;
  wallet_redeemable_minor?: number;
  risk?: { score?: number; decision?: string } & Record<string, unknown>;
}

const uuid = () => (typeof crypto !== "undefined" && crypto.randomUUID ? crypto.randomUUID() : `k-${Math.abs(Date.now())}`);

export async function createCheckoutPackage(body: { payment_method: string; coupon_code?: string }): Promise<CheckoutQuote> {
  const r = await authedFetch("cart/me/checkout-package", {
    method: "POST",
    headers: { "content-type": "application/json", "Idempotency-Key": uuid() },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`checkout-package failed: ${r.status}`);
  return (await r.json()) as CheckoutQuote;
}

export async function placeOrder(idemKey: string, quote: CheckoutQuote, paymentMethod: string): Promise<{ orderId?: string; status?: string }> {
  const items = quote.sub_orders.flatMap((so) =>
    so.items.map((it) => ({
      shop_id: so.shop_id,
      product_id: it.product_id,
      variant_id: it.variant_id,
      quantity: it.quantity,
      unit_price_minor: it.sale_price_minor ?? it.unit_price_minor,
    })),
  );
  const r = await authedFetch("order/orders", {
    method: "POST",
    headers: { "content-type": "application/json", "Idempotency-Key": idemKey },
    body: JSON.stringify({ checkout_id: quote.checkout_id, payment_method: paymentMethod, items }),
  });
  if (!r.ok) throw new Error(`order placement failed: ${r.status}`);
  return (await r.json()) as { orderId?: string; status?: string };
}
