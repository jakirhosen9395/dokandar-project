"use client";
/** Admin-portal data access via the BFF (Browser → BFF → gateway → service). admin + platform_staff only.
 *  Reachable: reporting, payment, risk, kyc, shipping-agents, per-user profile/wallet lookup. Blocked:
 *  seller mgmt (GAP-1), admin order list (GAP-13), user list (GAP-20), admin notifications (GAP-21). */
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

// reporting
export const getPlatformKpis = () => get<PlatformKpis>("reporting/platform-kpis");
export const getOrdersByPeriod = () => get<{ daily?: { date: string; orders: number; gmv_minor?: number }[] }>("reporting/orders-by-period");
export const getPaymentMix = () => get<{ by_provider?: Record<string, number>; by_provider_count?: Record<string, number> }>("reporting/payment-mix");
export const getPayoutsHistory = () => get<{ payouts?: unknown[] }>("reporting/payouts-history");
// payment
export const getCodLedger = () => get<unknown[]>("payment/cod-ledger");
export const getPayouts = () => get<unknown[]>("payment/payouts");
export const getCommissionRates = () => get<unknown[]>("payment/commission-rates");
// risk
export const getRiskRules = () => get<unknown[]>("risk/admin/rules");
export const createRiskRule = (b: unknown) => send("risk/admin/rules", "POST", b);
// kyc moderation
export const getKycQueue = () => get<{ items?: unknown[]; next_cursor?: string | null }>("auth/kyc/queue");
export const approveKyc = (id: string) => send(`auth/kyc/${id}/approve`, "POST");
export const rejectKyc = (id: string) => send(`auth/kyc/${id}/reject`, "POST", { reason: "rejected by admin" });
// per-user lookup
export const lookupProfile = (uid: string) => get<Record<string, unknown>>(`profile/admin/profiles/${uid}`);
export const lookupWallet = (uid: string) => get<Record<string, unknown>>(`wallet/balance/${uid}`);
// shipping agents
export const getShippingAgents = () => get<{ agents?: unknown[] }>("shipping/admin/agents");
// GAP-13 mitigation: no admin order list, but a specific order can be looked up by id
export const lookupOrder = (id: string) => get<Record<string, unknown>>(`order/orders/${id}`);

export interface PlatformKpis {
  period_from?: string; period_to?: string; gmv_minor?: number; orders?: number; aov_minor?: number; take_rate_pct?: number;
}
