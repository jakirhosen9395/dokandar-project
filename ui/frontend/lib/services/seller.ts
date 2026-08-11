"use client";
/** Seller-portal data access via the BFF (Browser → BFF → gateway → service). Bearer attached by
 *  authedFetch. Reachable: catalog (products) + coupon (list). Blocked at the API boundary: seller/shop
 *  service (GAP-1), seller order list (GAP-13), media (GAP-15/16), analytics/reporting. */
import { authedFetch } from "@/lib/auth-client";

async function get<T = unknown>(p: string): Promise<T | null> {
  const r = await authedFetch(p);
  return r.ok ? ((await r.json()) as T) : null;
}
async function send<T = unknown>(p: string, m: string, b?: unknown): Promise<T | null> {
  const r = await authedFetch(p, { method: m, headers: b ? { "content-type": "application/json" } : undefined, body: b ? JSON.stringify(b) : undefined });
  if (!r.ok) throw new Error(`${m} ${p} → ${r.status}`);
  return r.status === 204 ? null : ((await r.json()) as T);
}

// products (catalog write model) — functional; list-in-shop is GAP-1-blocked
export const getCatalogProducts = (limit = 100) => get<{ items?: CatProduct[]; products?: CatProduct[] }>(`catalog/products?limit=${limit}`);
export const getProduct = (id: string) => get<{ product?: CatProduct } & CatProduct>(`catalog/products/${id}`);
export const createProduct = (b: ProductInput) => send<{ product: CatProduct }>("catalog/products", "POST", b);
export const updateProduct = (id: string, b: Partial<ProductInput>) => send(`catalog/products/${id}`, "PUT", b);
export const deleteProduct = (id: string) => send(`catalog/products/${id}`, "DELETE");
// stock: shared-pool products take {on_hand, low_threshold} with NO shop_id (backend contract)
export const setStock = (variantId: string, on_hand: number, low_threshold = 5) => send(`catalog/stock/${variantId}`, "PUT", { on_hand, low_threshold });
export const setProductStatus = (id: string, status: "active" | "draft") => send<{ product: CatProduct }>(`catalog/products/${id}`, "PUT", { status });
export const addVariant = (id: string, b: { sku: string; list_price_minor: number; sale_price_minor?: number; options?: Record<string, string> }) => send<{ variant: { id: string } }>(`catalog/products/${id}/variants`, "POST", b);
export const deleteVariant = (id: string, vid: string) => send(`catalog/products/${id}/variants/${vid}`, "DELETE");
export const getCategoriesTree = () => get<{ tree?: SellerCategory[] }>("catalog/categories/tree");
// live reachability probe for the connection-diagnostics panel (returns the HTTP status, 0 on network error)
export async function checkReachable(path: string): Promise<number> {
  try {
    const r = await authedFetch(path);
    return r.status;
  } catch {
    return 0;
  }
}

// shop management — reachable via the gateway shop route (/api/v1/shop/*)
export const getMyShops = () => get<{ shops?: Shop[] }>("shop/me");
export const createShop = (b: ShopInput) => send<{ shop: Shop }>("shop/me", "POST", b);
export const updateShop = (id: string, b: Partial<ShopInput>) => send<{ shop: Shop }>(`shop/shops/${id}`, "PATCH", b);
export const activateShop = (id: string) => send<{ shop: Shop }>(`shop/shops/${id}/activate`, "POST");

// coupons — list functional; create needs a shop (GAP-1)
export const getMyCoupons = () => get<{ items?: Coupon[] } | Coupon[]>("coupon/coupons/me");
export const createCoupon = (b: unknown) => send("coupon/coupons", "POST", b);
export const revokeCoupon = (id: string) => send(`coupon/coupons/${id}/revoke`, "POST");
export const getFestivals = () => get<{ items?: unknown[] } | unknown[]>("coupon/festivals");

export interface CatProduct {
  id: string; owner_id?: string; name_en: string; name_bn: string; brand?: string | null; sku?: string | null;
  category_id?: string | null; list_price_minor?: number | null; sale_price_minor?: number | null; status?: string;
  variants?: { id: string; [k: string]: unknown }[]; [k: string]: unknown;
}
export interface ProductInput {
  name_en: string; name_bn: string; category_id: string; list_price_minor: number; sale_price_minor?: number;
  brand?: string; sku?: string; description_en?: string; description_bn?: string;
}
export interface SellerCategory { category_id: string; name_en: string; name_bn: string; children?: SellerCategory[]; [k: string]: unknown }
export interface Coupon { id?: string; code?: string; status?: string; kind?: string; valuePercent?: number; [k: string]: unknown }
export interface Shop { id: string; handle: string; name: string; name_bn?: string; description?: string; status?: string; contact_phone?: string; contact_email?: string; category_id?: string | null; [k: string]: unknown }
export interface ShopInput { handle: string; name: string; name_bn?: string; description?: string; contact_phone?: string; contact_email?: string; address?: string[]; category_id?: string }
