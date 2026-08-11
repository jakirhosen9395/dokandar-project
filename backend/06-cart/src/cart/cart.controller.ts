import { Body, Controller, Delete, Get, Headers, HttpCode, HttpException, HttpStatus, Param, Patch, Post, Req } from '@nestjs/common';
import { ApiBearerAuth, ApiHeader, ApiOperation, ApiParam, ApiResponse, ApiTags } from '@nestjs/swagger';
import { randomUUID } from 'crypto';
import { verifyToken } from '../auth/jwt';
import { config } from '../config';
import { RedisService } from '../redis.service';
import { CartService } from './cart.service';
import { CheckoutService } from './checkout.service';
import { cartItemMutations, SERVICE_VAL } from '../observability/metrics';
import { AddItemDto, AddWishlistDto, CartDocModel, CheckoutPackageDto, CheckoutPackageModel, ErrorEnvelopeModel, GuestCartModel, PatchItemDto, WishlistDocModel } from './dto';

function requireUser(req: any): any {
  const u = verifyToken(req.headers['authorization']);
  if (!u) throw new HttpException({ error: { code: 'unauthorized', message: 'valid Bearer token required' } }, HttpStatus.UNAUTHORIZED);
  return u;
}
function validateCookie(id: string): void {
  if (id.length < 8 || id.length > 80 || !/^[A-Za-z0-9_-]+$/.test(id)) throw new HttpException({ error: { code: 'invalid_cookie_id', message: 'cookie_id must be 8-80 chars [A-Za-z0-9_-]' } }, HttpStatus.BAD_REQUEST);
}

@ApiTags('cart')
@Controller('api/v1/cart')
export class CartController {
  constructor(private readonly cart: CartService, private readonly checkout: CheckoutService, private readonly redis: RedisService) {}

  // ── authenticated cart ──
  @Get('me') @ApiBearerAuth('HTTPBearer') @ApiOperation({ operationId: 'getMyCart', summary: "Get the authenticated user's cart", description: 'Returns the caller’s server-side cart (creating an empty one if none exists). Line prices are paisa (`*Minor`); `priceStale` flags lines whose snapshot price is older than the latest catalog change.' }) @ApiResponse({ status: 200, description: 'The current cart', type: CartDocModel }) @ApiResponse({ status: 401, description: 'token_missing / token_invalid', type: ErrorEnvelopeModel })
  async me(@Req() req: any) { return this.cart.getCart(String(requireUser(req).sub)); }

  @Post('me/items') @HttpCode(201) @ApiBearerAuth('HTTPBearer') @ApiOperation({ operationId: 'addCartItem', summary: 'Add or bump a cart line', description: 'Adds a product/variant line; if the same shop+variant is already present its quantity is increased (capped at 999).' }) @ApiResponse({ status: 201, description: 'Updated cart', type: CartDocModel }) @ApiResponse({ status: 401, description: 'token_missing / token_invalid', type: ErrorEnvelopeModel }) @ApiResponse({ status: 422, description: 'invalid_request (validation failed)', type: ErrorEnvelopeModel })
  async addItem(@Req() req: any, @Body() body: AddItemDto) { cartItemMutations.inc({ service: SERVICE_VAL, op: 'add' }); return this.cart.addItem(String(requireUser(req).sub), body); }

  @Patch('me/items/:lineId') @ApiBearerAuth('HTTPBearer') @ApiOperation({ operationId: 'patchCartItem', summary: 'Change a cart line quantity (0 → delete)', description: 'Sets an absolute new quantity for the line. A quantity of 0 removes the line.' }) @ApiParam({ name: 'lineId', description: 'Cart line id (hex, returned in the cart document)', example: 'a1b2c3d4e5f60718293a4b5c6d7e8f90' }) @ApiResponse({ status: 200, description: 'Updated cart', type: CartDocModel }) @ApiResponse({ status: 401, description: 'token_missing / token_invalid', type: ErrorEnvelopeModel }) @ApiResponse({ status: 404, description: 'line not found', type: ErrorEnvelopeModel }) @ApiResponse({ status: 422, description: 'invalid_request (validation failed)', type: ErrorEnvelopeModel })
  async patchItem(@Req() req: any, @Param('lineId') id: string, @Body() body: PatchItemDto) { cartItemMutations.inc({ service: SERVICE_VAL, op: 'patch' }); return this.cart.patchItem(String(requireUser(req).sub), id, body.quantity); }

  @Delete('me/items/:lineId') @ApiBearerAuth('HTTPBearer') @ApiOperation({ operationId: 'deleteCartItem', summary: 'Remove a cart line', description: 'Deletes a single line from the cart (idempotent).' }) @ApiParam({ name: 'lineId', description: 'Cart line id (hex)', example: 'a1b2c3d4e5f60718293a4b5c6d7e8f90' }) @ApiResponse({ status: 200, description: 'Updated cart', type: CartDocModel }) @ApiResponse({ status: 401, description: 'token_missing / token_invalid', type: ErrorEnvelopeModel })
  async deleteItem(@Req() req: any, @Param('lineId') id: string) { cartItemMutations.inc({ service: SERVICE_VAL, op: 'delete' }); return this.cart.deleteItem(String(requireUser(req).sub), id); }

  @Delete('me/items') @ApiBearerAuth('HTTPBearer') @ApiOperation({ operationId: 'clearCart', summary: 'Clear the cart', description: 'Removes every line from the caller’s cart (idempotent).' }) @ApiResponse({ status: 200, description: 'Emptied cart', type: CartDocModel }) @ApiResponse({ status: 401, description: 'token_missing / token_invalid', type: ErrorEnvelopeModel })
  async clear(@Req() req: any) { cartItemMutations.inc({ service: SERVICE_VAL, op: 'clear' }); return this.cart.clearCart(String(requireUser(req).sub)); }

  // ── checkout-package quote ──
  @Post('me/checkout-package') @ApiBearerAuth('HTTPBearer') @ApiHeader({ name: 'Idempotency-Key', required: true, description: 'Unique key for the quote; replaying the same key returns the same package.', example: 'co-2026-06-20-0001' }) @ApiOperation({ operationId: 'buildCheckoutPackage', summary: 'Build the immutable checkout-package quote (idempotent)', description: 'Fans out to catalog (CheckStock, fail-closed), coupon (ValidateCoupon, fail-open) and risk (ScoreCheckout). Produces one sub-order per shop and a grand total in paisa. The quote is what 13-order replays at place time.' }) @ApiResponse({ status: 200, description: 'The checkout-package quote', type: CheckoutPackageModel }) @ApiResponse({ status: 401, description: 'token_missing / token_invalid', type: ErrorEnvelopeModel }) @ApiResponse({ status: 409, description: 'cart empty / stock conflict / idempotency conflict', type: ErrorEnvelopeModel }) @ApiResponse({ status: 422, description: 'invalid_request (validation failed)', type: ErrorEnvelopeModel })
  async checkoutPackage(@Req() req: any, @Body() body: CheckoutPackageDto, @Headers('idempotency-key') idem?: string) { return this.checkout.build(requireUser(req), body, idem); }

  // ── wishlist ──
  @Get('wishlist') @ApiBearerAuth('HTTPBearer') @ApiOperation({ operationId: 'getWishlist', summary: 'Get the wishlist', description: 'Returns the caller’s wishlist (creating an empty one if none exists).' }) @ApiResponse({ status: 200, description: 'The wishlist', type: WishlistDocModel }) @ApiResponse({ status: 401, description: 'token_missing / token_invalid', type: ErrorEnvelopeModel })
  async wishlist(@Req() req: any) { return this.cart.getWishlist(String(requireUser(req).sub)); }
  @Post('wishlist/items') @HttpCode(201) @ApiBearerAuth('HTTPBearer') @ApiOperation({ operationId: 'addWishlistItem', summary: 'Add a product to the wishlist', description: 'Adds a product (optionally a specific variant) to the wishlist.' }) @ApiResponse({ status: 201, description: 'Updated wishlist', type: WishlistDocModel }) @ApiResponse({ status: 401, description: 'token_missing / token_invalid', type: ErrorEnvelopeModel }) @ApiResponse({ status: 422, description: 'invalid_request (validation failed)', type: ErrorEnvelopeModel })
  async wishlistAdd(@Req() req: any, @Body() body: AddWishlistDto) { return this.cart.addWishlist(String(requireUser(req).sub), body); }
  @Delete('wishlist/items/:lineId') @ApiBearerAuth('HTTPBearer') @ApiOperation({ operationId: 'removeWishlistItem', summary: 'Remove a wishlist item', description: 'Removes a single wishlist line (idempotent).' }) @ApiParam({ name: 'lineId', description: 'Wishlist line id (hex)', example: 'a1b2c3d4e5f60718293a4b5c6d7e8f90' }) @ApiResponse({ status: 200, description: 'Updated wishlist', type: WishlistDocModel }) @ApiResponse({ status: 401, description: 'token_missing / token_invalid', type: ErrorEnvelopeModel })
  async wishlistRemove(@Req() req: any, @Param('lineId') id: string) { return this.cart.removeWishlist(String(requireUser(req).sub), id); }

  // ── guest cart (public, cookie-id-scoped) ──
  @Get('guest/:cookieId') @ApiOperation({ operationId: 'getGuestCart', summary: 'Get the guest cart', description: 'Public, cookie-id-scoped cart held in Redis DB5. Reading refreshes the TTL. Returns an empty cart if the cookie has none.' }) @ApiParam({ name: 'cookieId', description: 'Opaque guest cookie id, 8–80 chars matching ^[A-Za-z0-9_-]+$', example: 'guest-abc123def456' }) @ApiResponse({ status: 200, description: 'The guest cart', type: GuestCartModel }) @ApiResponse({ status: 400, description: 'invalid_cookie_id', type: ErrorEnvelopeModel })
  async guestGet(@Param('cookieId') cookieId: string) {
    validateCookie(cookieId);
    const raw = await this.redis.client.get(`guest:cart:${cookieId}`);
    const ttl = Math.max(60, config.guestCartTtlDays * 86400);
    if (raw) { await this.redis.client.expire(`guest:cart:${cookieId}`, ttl); try { return JSON.parse(raw); } catch {} }
    return { cookie_id: cookieId, items: [], updated_at: new Date().toISOString() };
  }
  @Post('guest/:cookieId/items') @HttpCode(201) @ApiOperation({ operationId: 'addGuestCartItem', summary: 'Add an item to the guest cart', description: 'Adds a line to the cookie-scoped guest cart (creating it if absent) and refreshes its TTL. Prices are resolved later at merge / checkout time.' }) @ApiParam({ name: 'cookieId', description: 'Opaque guest cookie id, 8–80 chars matching ^[A-Za-z0-9_-]+$', example: 'guest-abc123def456' }) @ApiResponse({ status: 201, description: 'Updated guest cart', type: GuestCartModel }) @ApiResponse({ status: 400, description: 'invalid_cookie_id', type: ErrorEnvelopeModel }) @ApiResponse({ status: 422, description: 'invalid_request (validation failed)', type: ErrorEnvelopeModel })
  async guestAdd(@Param('cookieId') cookieId: string, @Body() body: AddItemDto) {
    validateCookie(cookieId);
    const ttl = Math.max(60, config.guestCartTtlDays * 86400);
    const raw = await this.redis.client.get(`guest:cart:${cookieId}`);
    let items: any[] = []; if (raw) { try { items = JSON.parse(raw).items || []; } catch {} }
    const ex = items.find((i) => i.shopId === body.shop_id && i.variantId === body.variant_id);
    if (ex) { ex.quantity = Math.min(999, (ex.quantity || 0) + body.quantity); ex.priceStale = true; ex.snapshotAt = new Date().toISOString(); }
    else items.push({ lineId: randomUUID().replace(/-/g, ''), shopId: body.shop_id, productId: body.product_id, variantId: body.variant_id, quantity: body.quantity, unitPriceMinor: 0, salePriceMinor: null, attributes: body.attributes || {}, snapshotAt: new Date().toISOString(), priceStale: false });
    const payload = { cookie_id: cookieId, items, updated_at: new Date().toISOString() };
    await this.redis.client.set(`guest:cart:${cookieId}`, JSON.stringify(payload), 'EX', ttl);
    return payload;
  }
  @Post('guest/:cookieId/merge') @HttpCode(200) @ApiBearerAuth('HTTPBearer') @ApiOperation({ operationId: 'mergeGuestCart', summary: "Merge a guest cart into the authenticated user's cart", description: 'Folds every line of the cookie-scoped guest cart into the caller’s server-side cart, then deletes the guest cart. Returns the merged authenticated cart.' }) @ApiParam({ name: 'cookieId', description: 'Opaque guest cookie id, 8–80 chars matching ^[A-Za-z0-9_-]+$', example: 'guest-abc123def456' }) @ApiResponse({ status: 200, description: 'The merged authenticated cart', type: CartDocModel }) @ApiResponse({ status: 400, description: 'invalid_cookie_id', type: ErrorEnvelopeModel }) @ApiResponse({ status: 401, description: 'missing_token', type: ErrorEnvelopeModel })
  async guestMerge(@Req() req: any, @Param('cookieId') cookieId: string) {
    const u = verifyToken(req.headers['authorization']);
    if (!u) throw new HttpException({ error: { code: 'missing_token', message: 'Bearer token required to merge' } }, HttpStatus.UNAUTHORIZED);
    validateCookie(cookieId);
    const userId = String(u.sub);
    const raw = await this.redis.client.get(`guest:cart:${cookieId}`);
    if (!raw) return this.cart.getCart(userId);
    let items: any[] = []; try { items = JSON.parse(raw).items || []; } catch {}
    for (const it of items) { try { await this.cart.addItem(userId, { shop_id: it.shopId, product_id: it.productId, variant_id: it.variantId, quantity: parseInt(it.quantity) || 1, attributes: it.attributes || {} }); } catch {} }
    await this.redis.client.del(`guest:cart:${cookieId}`);
    return this.cart.getCart(userId);
  }
}
