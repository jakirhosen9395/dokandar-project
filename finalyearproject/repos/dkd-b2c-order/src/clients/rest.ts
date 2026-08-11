// Downstream REST seams: inventory strong-local Reserve (BR-022/G2 — REST substitution for
// the gRPC OHS, fleet decision D9) and catalog master-data conformance (R7).
import { ApiError } from "../http/router.js";

interface Envelope { success: boolean; data?: unknown; error?: { code?: string; detail?: string } }

async function call(url: string, init: RequestInit, timeoutMs = 8000): Promise<{ status: number; body: Envelope }> {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const res = await fetch(url, { ...init, signal: ctl.signal });
    const body = (await res.json().catch(() => ({}))) as Envelope;
    return { status: res.status, body };
  } finally {
    clearTimeout(timer);
  }
}

export class InventoryClient {
  constructor(private readonly baseUrl: string) {}

  /** @returns reservation id; throws 409 ApiError on insufficient strong-local stock. */
  async reserve(idemKey: string, gpid: string, holderDid: string, quantity: bigint): Promise<string> {
    const { status, body } = await call(`${this.baseUrl}/v1/inventory/reservations`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Idempotency-Key": idemKey },
      body: JSON.stringify({ gpid, holder: holderDid, quantity: Number(quantity) }),
    });
    if (status === 201 || status === 200) {
      const resId = (body.data as { resId?: string } | undefined)?.resId;
      if (resId) return resId;
      throw new ApiError(502, "dokandar.b2c.inventory.bad_response", "reservation response had no resId");
    }
    if (status === 409)
      throw new ApiError(409, "dokandar.b2c.order.insufficient_stock",
        `strong-local stock below requested quantity for ${gpid}`);
    throw new ApiError(503, "dokandar.b2c.inventory.unavailable", `inventory reserve failed (${status})`);
  }

  async transition(resId: string, action: "release" | "confirm"): Promise<void> {
    const { status } = await call(`${this.baseUrl}/v1/inventory/reservations/${encodeURIComponent(resId)}/${action}`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: "{}",
    });
    if (status >= 400 && status !== 409)
      throw new ApiError(503, "dokandar.b2c.inventory.unavailable", `reservation ${action} failed (${status})`);
  }
}

export class CatalogClient {
  constructor(private readonly baseUrl: string) {}

  /** R7 conformance: the GPID must exist and be PUBLISHED before an order references it. */
  async requirePublished(gpid: string): Promise<void> {
    const { status, body } = await call(`${this.baseUrl}/v1/catalog/products/${encodeURIComponent(gpid)}`, {
      method: "GET",
    });
    if (status === 404)
      throw new ApiError(409, "dokandar.b2c.order.unknown_product", `no catalog product for ${gpid} (R7)`);
    if (status >= 400)
      throw new ApiError(503, "dokandar.b2c.catalog.unavailable", `catalog lookup failed (${status})`);
    const productStatus = (body.data as { status?: string } | undefined)?.status;
    if (productStatus !== "PUBLISHED")
      throw new ApiError(409, "dokandar.b2c.order.product_not_published",
        `${gpid} is ${productStatus ?? "UNKNOWN"}, not PUBLISHED`);
  }
}
