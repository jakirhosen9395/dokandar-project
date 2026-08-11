"use client";
/** Customer-portal data access — all via the BFF (Browser → BFF → gateway → service), Bearer attached
 *  by authedFetch (refresh-on-401). No internal URLs in the browser. */
import { authedFetch } from "@/lib/auth-client";

async function get<T = unknown>(path: string): Promise<T | null> {
  const r = await authedFetch(path);
  return r.ok ? ((await r.json()) as T) : null;
}
async function send<T = unknown>(path: string, method: string, body?: unknown): Promise<T | null> {
  const r = await authedFetch(path, {
    method,
    headers: body ? { "content-type": "application/json" } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!r.ok) throw new Error(`${method} ${path} → ${r.status}`);
  return r.status === 204 ? null : ((await r.json()) as T);
}

// profile
export const getProfile = () => get("profile/me");
export const updateProfile = (b: unknown) => send("profile/me", "PATCH", b);
// addresses
export const getAddresses = () => get<{ items: unknown[] }>("profile/me/addresses");
export const createAddress = (b: unknown) => send("profile/me/addresses", "POST", b);
export const updateAddress = (id: string, b: unknown) => send(`profile/me/addresses/${id}`, "PATCH", b);
export const deleteAddress = (id: string) => send(`profile/me/addresses/${id}`, "DELETE");
export const setDefaultAddress = (id: string) => send(`profile/me/addresses/${id}/default`, "POST");
// geo (for the address form cascade)
export const getGeo = (path: string) => get<{ items: GeoNode[] }>(`profile/geo/${path}`);
// orders
export const getOrders = () => get<{ orders: unknown[] }>("order/orders/me");
export const getOrder = (id: string) => get(`order/orders/${id}`);
// wallet
export const getWallet = () => get<Wallet>("wallet/me");
export const getWalletEntries = (size = 25) => get<WalletEntry[]>(`wallet/me/entries?size=${size}`);
export const getCashbackRules = () => get<CashbackRule[]>("wallet/cashback-rules");
// top-up credits the wallet directly (dev); requires an Idempotency-Key like checkout/order.
export async function topupWallet(amount_minor: number): Promise<Wallet> {
  const key = typeof crypto !== "undefined" && crypto.randomUUID ? crypto.randomUUID() : `k-${Date.now()}`;
  const r = await authedFetch("wallet/me/topup", {
    method: "POST",
    headers: { "content-type": "application/json", "Idempotency-Key": key },
    body: JSON.stringify({ amount_minor }),
  });
  if (!r.ok) throw new Error(`topup failed: ${r.status}`);
  return (await r.json()) as Wallet;
}
// notifications
export const getInbox = (page = 1, size = 20) => get<Inbox>(`notification/inbox?page=${page}&size=${size}`);
export const markRead = (id: string) => send(`notification/inbox/${id}/read`, "POST");
export const markAllRead = () => send("notification/inbox/read-all", "POST");
export const getNotifPrefs = () => get<Record<string, unknown>>("notification/preferences");
export const updateNotifPrefs = (b: unknown) => send("notification/preferences", "PUT", b);
// reviews (GAP-10: list filter for "mine" unverified — treated as the authed user's reviews)
export const getMyReviews = () => get<unknown[]>("review/reviews");
export const deleteReview = (id: string) => send(`review/reviews/${id}`, "DELETE");
// wishlist
export const getWishlist = () => get<{ items: WishItem[] }>("cart/wishlist");
export const removeWishlist = (lineId: string) => send(`cart/wishlist/items/${lineId}`, "DELETE");
// GAP-8: shipment tracking — 17-shipping is customer-reachable by sub-order id
export const getShipmentByOrder = (subOrderId: string) => get<Record<string, unknown>>(`shipping/shipments/by-order/${subOrderId}`);

export interface GeoNode { code: string; name_en?: string; name_bn?: string; [k: string]: unknown }
export interface Wallet { balance_minor?: number; available_minor?: number; currency?: string; status?: string; [k: string]: unknown }
export interface WalletEntry { id?: string; credit_minor?: number; debit_minor?: number; kind?: string; posted_at?: string; idempotency_key?: string; [k: string]: unknown }
export interface CashbackRule { id?: string; trigger?: string; funded_by?: string; reward_kind?: string; reward_value?: number; reward_cap_minor?: number; min_subtotal_minor?: number; max_per_user?: number; [k: string]: unknown }
export interface Inbox { items: NotificationItem[]; page: number; size: number; total: number }
export interface NotificationItem { id: string; title?: string; body?: string; read?: boolean; read_at?: string | null; created_at?: string; [k: string]: unknown }
export interface WishItem { line_id?: string; lineId?: string; product_id: string; variant_id?: string; shop_id?: string; [k: string]: unknown }
