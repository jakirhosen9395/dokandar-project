// REST clients for the quote fan-out (catalog exposes REST + gRPC; the platform
// env standard wires CATALOG_HTTP_URL, so we use REST). Policy per architecture §13:
// catalog fail-closed, coupon fail-open, risk fail-closed/hold-for-COD.
// The peer HTTP calls below are auto-instrumented by the Node APM agent; a span filter
// in apm.ts renames their destination from the raw IP:port to the friendly service name
// (04-catalog / 07-coupon / 18-risk-trust) so the Dependencies tab + service map are clean.
import axios from 'axios';
import { config } from '../config';
import { logger } from '../observability/logger';
import { cartGrpcCalls, SERVICE_VAL } from '../observability/metrics';

export class CatalogUnavailable extends Error {}

export async function checkStock(items: { productId: string; variantId: string; quantity: number }[]): Promise<Record<string, any>> {
  const out: Record<string, any> = {};
  if (!config.catalogHttpUrl) { cartGrpcCalls.inc({ service: SERVICE_VAL, peer: 'catalog', result: 'fail' }); throw new CatalogUnavailable('catalog_http_url empty'); }
  for (const it of items) {
    const url = `${config.catalogHttpUrl.replace(/\/$/, '')}/api/v1/catalog/products/${it.productId}`;
    let r: any;
    try { r = await axios.get(url, { timeout: config.grpcDeadlineCatalog, validateStatus: () => true }); }
    catch (e: any) { cartGrpcCalls.inc({ service: SERVICE_VAL, peer: 'catalog', result: 'fail' }); throw new CatalogUnavailable(e?.code || e?.message || 'error'); }
    if (r.status === 404) { out[it.variantId] = { in_stock: false, available_qty: 0 }; continue; }
    if (r.status !== 200) { cartGrpcCalls.inc({ service: SERVICE_VAL, peer: 'catalog', result: 'fail' }); throw new CatalogUnavailable(`http_${r.status}`); }
    const p = (r.data && r.data.product) ? r.data.product : (r.data || {});
    let unit = Number(p.list_price_minor ?? p.price_minor ?? 0);
    let sale = p.sale_price_minor ?? null;
    let inStock = p.in_stock !== false;
    let avail = Number(p.available_qty ?? 999);
    const variants = p.variants || p.product_variants || [];
    if (Array.isArray(variants)) {
      const v = variants.find((x: any) => String(x.variant_id ?? x.id) === it.variantId);
      if (v) { unit = Number(v.list_price_minor ?? unit); if (v.sale_price_minor != null) sale = v.sale_price_minor; if (v.available_qty != null) { avail = Number(v.available_qty); inStock = avail > 0; } }
    }
    out[it.variantId] = { in_stock: inStock, available_qty: avail, unit_price_minor: unit, sale_price_minor: sale };
  }
  cartGrpcCalls.inc({ service: SERVICE_VAL, peer: 'catalog', result: 'ok' });
  return out;
}

export async function validateCoupon(code: string | undefined, userId: string, subtotal: number): Promise<any> {
  if (!code || !config.couponHttpUrl) return { valid: false, discount_minor: 0, reason: 'not_configured' };
  try {
    const r = await axios.post(`${config.couponHttpUrl.replace(/\/$/, '')}/api/v1/coupon/validate`, { code, user_id: userId, subtotal_minor: subtotal }, { timeout: config.grpcDeadlineCoupon, validateStatus: () => true });
    if (r.status !== 200) return { valid: false, discount_minor: 0, reason: `http_${r.status}` };
    const b = r.data || {}; return { valid: !!b.valid, discount_minor: Number(b.discount_minor || 0), reason: b.reason };
  } catch (e: any) { logger.warn('cart.coupon', `validate failed (fail-open): ${e?.message}`); return { valid: false, discount_minor: 0, reason: 'unavailable' }; }
}

export async function scoreCheckout(userId: string, paymentMethod: string, total: number): Promise<any> {
  if (!config.riskHttpUrl) {
    if (paymentMethod === 'cod') return { decision: 'hold', score: 0, reason: 'not_configured', hold_reason: 'cod_risk_unverified' };
    return { decision: 'ok', score: 0, reason: 'not_configured' };
  }
  try {
    const r = await axios.post(`${config.riskHttpUrl.replace(/\/$/, '')}/api/v1/risk/score-checkout`, { user_id: userId, payment_method: paymentMethod, grand_total_minor: total }, { timeout: config.grpcDeadlineRisk, validateStatus: () => true });
    if (r.status !== 200) { if (paymentMethod === 'cod') return { decision: 'hold', score: 0, reason: `http_${r.status}`, hold_reason: 'cod_risk_http_error' }; return { decision: 'ok', score: 0, reason: `http_${r.status}` }; }
    const b = r.data || {}; return { decision: b.decision || 'ok', score: Number(b.score || 0), reason: b.reason, hold_reason: b.hold_reason };
  } catch (e: any) { if (paymentMethod === 'cod') return { decision: 'hold', score: 0, reason: 'unavailable', hold_reason: 'cod_risk_unreachable' }; return { decision: 'ok', score: 0, reason: 'unavailable' }; }
}
