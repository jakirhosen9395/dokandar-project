import { HttpException, HttpStatus, Injectable } from '@nestjs/common';
import { randomUUID } from 'crypto';
import { CartService } from './cart.service';
import { RedisService } from '../redis.service';
import { config } from '../config';
import { checkStock, validateCoupon, scoreCheckout, CatalogUnavailable } from '../downstream/clients';
import { cartCheckoutTotal, cartIdemHits, cartCheckoutBuildMs, cartGrpcCalls, SERVICE_VAL } from '../observability/metrics';
import { logger } from '../observability/logger';

@Injectable()
export class CheckoutService {
  constructor(private readonly cart: CartService, private readonly redis: RedisService) {}

  async build(user: any, body: any, idemKey?: string): Promise<any> {
    const userId = String(user.sub);
    if (!idemKey) throw new HttpException({ error: { code: 'missing_idempotency_key', message: 'Idempotency-Key header required' } }, HttpStatus.BAD_REQUEST);
    const cached = await this.redis.client.get(`cart:idem:${userId}:${idemKey}`);
    if (cached) { cartIdemHits.inc({ service: SERVICE_VAL }); logger.info('cart.checkout', `checkout-package replay user=${userId}`); return JSON.parse(cached); }
    const token = await this.redis.acquireLock(userId);
    if (!token) { cartCheckoutTotal.inc({ service: SERVICE_VAL, outcome: 'concurrent_checkout' }); throw new HttpException({ error: { code: 'concurrent_checkout', message: 'another checkout is in progress' } }, HttpStatus.CONFLICT); }
    const t0 = Date.now();
    try {
      const cart = await this.cart.getCart(userId);
      if (!cart.items || cart.items.length === 0) { cartCheckoutTotal.inc({ service: SERVICE_VAL, outcome: 'empty_cart' }); throw new HttpException({ error: { code: 'empty_cart', message: 'cart is empty' } }, HttpStatus.BAD_REQUEST); }
      let stock: Record<string, any>;
      try { stock = await checkStock(cart.items.map((i: any) => ({ productId: i.productId, variantId: i.variantId, quantity: i.quantity }))); }
      catch (e: any) { if (e instanceof CatalogUnavailable) { cartCheckoutTotal.inc({ service: SERVICE_VAL, outcome: 'dependency_unavailable' }); throw new HttpException({ error: { code: 'dependency_unavailable', message: 'catalog unreachable; cannot price-freeze', details: { cause: e.message } } }, HttpStatus.CONFLICT); } throw e; }
      for (const [vid, st] of Object.entries<any>(stock)) { if (!st.in_stock) { cartCheckoutTotal.inc({ service: SERVICE_VAL, outcome: 'stock_changed' }); throw new HttpException({ error: { code: 'stock_changed', message: 'one or more lines are out of stock', details: { variant_id: vid } } }, HttpStatus.CONFLICT); } }
      const { subOrders, couponApplied, subtotalGlobal } = await this.assemble(cart, stock, body, userId);
      const risk = await scoreCheckout(userId, body.payment_method || 'cod', subtotalGlobal);
      cartGrpcCalls.inc({ service: SERVICE_VAL, peer: 'risk', result: ['ok', 'hold'].includes(risk.decision) ? 'ok' : 'fail' });
      if (risk.decision === 'block') { cartCheckoutTotal.inc({ service: SERVICE_VAL, outcome: 'risk_block' }); throw new HttpException({ error: { code: 'risk_block', message: 'checkout blocked by risk policy', details: { reason: risk.reason } } }, HttpStatus.CONFLICT); }
      let grand = Math.max(0, subOrders.reduce((a: number, s: any) => a + s.shop_total_minor, 0) - couponApplied.discount_minor);
      const walletRedeem = Math.min(body.wallet_redeem_minor || 0, grand); grand -= walletRedeem;
      const pkg = { checkout_id: randomUUID().replace(/-/g, ''), user_id: userId, sub_orders: subOrders, coupon_applied: couponApplied, wallet_redeemable_minor: walletRedeem, risk: { decision: risk.decision, hold_reason: risk.hold_reason ?? null }, grand_total_minor: grand, issued_at: new Date().toISOString() };
      await this.redis.client.set(`cart:idem:${userId}:${idemKey}`, JSON.stringify(pkg), 'EX', Math.max(60, config.idempotencyTtlHours * 3600));
      cartCheckoutTotal.inc({ service: SERVICE_VAL, outcome: 'ok' }); cartCheckoutBuildMs.observe({ service: SERVICE_VAL }, Date.now() - t0);
      logger.info('cart.checkout', `checkout-package ok user=${userId} checkout_id=${pkg.checkout_id} grand_total=${grand}`);
      return pkg;
    } finally { await this.redis.releaseLock(userId, token); }
  }

  private async assemble(cart: any, stock: any, body: any, userId: string): Promise<any> {
    const grouped: Record<string, any[]> = {};
    for (const it of cart.items) {
      const st = stock[it.variantId] || {};
      const unit = Number(st.unit_price_minor ?? it.unitPriceMinor ?? 0);
      const sale = st.sale_price_minor ?? it.salePriceMinor ?? null;
      const eff = sale != null ? sale : unit;
      const lineTotal = eff * it.quantity;
      (grouped[it.shopId] = grouped[it.shopId] || []).push({ item: { product_id: it.productId, variant_id: it.variantId, quantity: it.quantity, unit_price_minor: unit, sale_price_minor: sale, line_total_minor: lineTotal }, lineTotal });
    }
    const subtotalGlobal = Object.values(grouped).reduce((a, arr) => a + arr.reduce((b, x) => b + x.lineTotal, 0), 0);
    const coupon = await validateCoupon(body.coupon_code, userId, subtotalGlobal);
    cartGrpcCalls.inc({ service: SERVICE_VAL, peer: 'coupon', result: coupon.valid ? 'ok' : 'fail' });
    const couponApplied = { code: body.coupon_code || null, discount_minor: Number(coupon.discount_minor || 0), valid: !!coupon.valid, reason: coupon.reason || null };
    const subOrders: any[] = [];
    for (const [shopId, arr] of Object.entries(grouped)) {
      const subtotalShop = arr.reduce((a, x) => a + x.lineTotal, 0);
      const shopDiscount = subtotalGlobal > 0 && couponApplied.discount_minor > 0 ? Math.floor((couponApplied.discount_minor * subtotalShop) / subtotalGlobal) : 0;
      const tax = Math.floor((subtotalShop * config.defaultTaxPercent) / 100);
      subOrders.push({ shop_id: shopId, items: arr.map((x) => x.item), subtotal_minor: subtotalShop, delivery_fee_minor: 0, tax_minor: tax, coupon_discount_minor: shopDiscount, shop_total_minor: Math.max(0, subtotalShop + tax - shopDiscount) });
    }
    return { subOrders, couponApplied, subtotalGlobal };
  }
}
