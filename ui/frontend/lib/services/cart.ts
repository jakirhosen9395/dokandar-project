"use client";
import { authedFetch } from "@/lib/auth-client";
import { useGuestCart } from "@/stores/guest-cart";
import type { Cart } from "@/types/marketplace";

// Cart is authed-only (the gateway 401s guest-cart paths — GAP-4). authedFetch attaches the Bearer
// and refreshes on 401. All calls go Browser → BFF → gateway → 06-cart.
export async function getCart(): Promise<Cart | null> {
  const r = await authedFetch("cart/me");
  return r.ok ? ((await r.json()) as Cart) : null;
}

export async function addToCart(input: {
  shop_id: string;
  product_id: string;
  variant_id: string;
  quantity: number;
}): Promise<Cart | null> {
  const r = await authedFetch("cart/me/items", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(input),
  });
  if (!r.ok) throw new Error(`add failed: ${r.status}`);
  return (await r.json()) as Cart;
}

export async function updateQty(lineId: string, quantity: number): Promise<Cart | null> {
  const r = await authedFetch(`cart/me/items/${lineId}`, {
    method: "PATCH",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ quantity }),
  });
  if (!r.ok) throw new Error(`update failed: ${r.status}`);
  return (await r.json()) as Cart;
}

export async function removeItem(lineId: string): Promise<Cart | null> {
  const r = await authedFetch(`cart/me/items/${lineId}`, { method: "DELETE" });
  if (!r.ok) throw new Error(`remove failed: ${r.status}`);
  return r.status === 204 ? null : ((await r.json()) as Cart);
}

export async function addToWishlist(product_id: string, variant_id?: string): Promise<boolean> {
  const r = await authedFetch("cart/wishlist/items", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(variant_id ? { product_id, variant_id } : { product_id }),
  });
  return r.ok;
}

// GAP-4: on login, replay the client-side guest cart into the server cart, then clear it.
export async function mergeGuestCart(): Promise<boolean> {
  const { items, clear } = useGuestCart.getState();
  if (!items.length) return false;
  for (const l of items) {
    try {
      await addToCart({ shop_id: l.shop_id, product_id: l.product_id, variant_id: l.variant_id, quantity: l.quantity });
    } catch {
      /* skip a line that fails (e.g. stock gone) — best-effort merge */
    }
  }
  clear();
  return true;
}
