import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { IsInt, IsObject, IsOptional, IsString, IsUUID, Max, Min } from 'class-validator';

export class AddItemDto {
  @ApiProperty({ format: 'uuid', description: 'shop that owns the listing', example: '11111111-1111-4111-8111-111111111111' }) @IsString() shop_id: string;
  @ApiProperty({ format: 'uuid', description: 'product id from 04-catalog', example: '22222222-2222-4222-8222-222222222222' }) @IsString() product_id: string;
  @ApiProperty({ format: 'uuid', description: 'variant id from 04-catalog', example: '33333333-3333-4333-8333-333333333333' }) @IsString() variant_id: string;
  @ApiProperty({ minimum: 1, maximum: 999, description: 'units to add (capped at 999)', example: 1 }) @IsInt() @Min(1) @Max(999) quantity: number;
  @ApiPropertyOptional({ type: 'object', additionalProperties: true, description: 'free-form variant attributes', example: { size: 'M', color: 'red' } }) @IsOptional() @IsObject() attributes?: Record<string, any>;
}
export class PatchItemDto {
  @ApiProperty({ minimum: 0, maximum: 999, description: 'new absolute quantity (0 → delete the line)', example: 2 }) @IsInt() @Min(0) @Max(999) quantity: number;
}
export class AddWishlistDto {
  @ApiProperty({ format: 'uuid', description: 'product id from 04-catalog', example: '22222222-2222-4222-8222-222222222222' }) @IsString() product_id: string;
  @ApiPropertyOptional({ format: 'uuid', description: 'optional specific variant', example: '33333333-3333-4333-8333-333333333333' }) @IsOptional() @IsString() variant_id?: string;
}
export class CheckoutPackageDto {
  @ApiPropertyOptional({ description: 'festival/discount coupon code (validated fail-open against 07-coupon)', example: 'EID2026' }) @IsOptional() @IsString() coupon_code?: string;
  @ApiPropertyOptional({ type: 'object', additionalProperties: { type: 'string' }, description: 'shop_id → delivery method (home|pickup)', example: { '11111111-1111-4111-8111-111111111111': 'home' } }) @IsOptional() @IsObject() delivery_methods?: Record<string, string>;
  @ApiPropertyOptional({ type: 'object', additionalProperties: { type: 'string' }, description: 'shop_id → delivery slot id', example: { '11111111-1111-4111-8111-111111111111': 'slot-am' } }) @IsOptional() @IsObject() delivery_slots?: Record<string, string>;
  @ApiPropertyOptional({ minimum: 0, default: 0, description: 'wallet amount to redeem, in paisa (integer)', example: 0 }) @IsOptional() @IsInt() @Min(0) wallet_redeem_minor?: number;
  @ApiPropertyOptional({ default: 'cod', enum: ['cod', 'bkash', 'nagad', 'card', 'wallet'], description: 'intended payment method', example: 'cod' }) @IsOptional() @IsString() payment_method?: string;
}

// ── response models (Swagger schemas) ──────────────────────────────────────
export class CartLineModel {
  @ApiProperty() lineId: string; @ApiProperty() shopId: string; @ApiProperty() productId: string;
  @ApiProperty() variantId: string; @ApiProperty() quantity: number; @ApiProperty() unitPriceMinor: number;
  @ApiPropertyOptional({ nullable: true }) salePriceMinor: number | null;
  @ApiProperty({ type: 'object', additionalProperties: true }) attributes: Record<string, any>;
  @ApiProperty() snapshotAt: string; @ApiProperty() priceStale: boolean;
}
export class CartDocModel {
  @ApiProperty() userId: string; @ApiProperty({ type: [CartLineModel] }) items: CartLineModel[];
  @ApiProperty() createdAt: string; @ApiProperty() updatedAt: string;
}
export class WishlistLineModel { @ApiProperty() lineId: string; @ApiProperty() productId: string; @ApiPropertyOptional({ nullable: true }) variantId: string | null; @ApiProperty() addedAt: string; }
export class WishlistDocModel { @ApiProperty() userId: string; @ApiProperty({ type: [WishlistLineModel] }) items: WishlistLineModel[]; }
export class GuestCartModel { @ApiProperty() cookie_id: string; @ApiProperty({ type: [CartLineModel] }) items: CartLineModel[]; @ApiProperty() updated_at: string; }
export class SubOrderItemModel { @ApiProperty() product_id: string; @ApiProperty() variant_id: string; @ApiProperty() quantity: number; @ApiProperty() unit_price_minor: number; @ApiPropertyOptional({ nullable: true }) sale_price_minor: number | null; @ApiProperty() line_total_minor: number; }
export class SubOrderModel { @ApiProperty() shop_id: string; @ApiProperty({ type: [SubOrderItemModel] }) items: SubOrderItemModel[]; @ApiProperty() subtotal_minor: number; @ApiProperty() delivery_fee_minor: number; @ApiProperty() tax_minor: number; @ApiProperty() coupon_discount_minor: number; @ApiProperty() shop_total_minor: number; }
export class CouponAppliedModel { @ApiPropertyOptional({ nullable: true }) code: string | null; @ApiProperty() discount_minor: number; @ApiProperty() valid: boolean; @ApiPropertyOptional({ nullable: true }) reason: string | null; }
export class CheckoutPackageModel {
  @ApiProperty() checkout_id: string; @ApiProperty() user_id: string;
  @ApiProperty({ type: [SubOrderModel] }) sub_orders: SubOrderModel[];
  @ApiProperty({ type: CouponAppliedModel }) coupon_applied: CouponAppliedModel;
  @ApiProperty() wallet_redeemable_minor: number;
  @ApiProperty({ type: 'object', additionalProperties: true, description: 'decision: ok|hold|block' }) risk: Record<string, any>;
  @ApiProperty() grand_total_minor: number; @ApiProperty() issued_at: string;
}
export class ErrorEnvelopeModel {
  @ApiProperty({
    type: 'object',
    description: 'Platform error envelope. `code` is a lowercase snake_case machine code; `request_id` echoes the honour-or-mint x-request-id header.',
    properties: {
      code: { type: 'string', example: 'invalid_request' },
      message: { type: 'string', example: 'request validation failed' },
      request_id: { type: 'string', example: 'a1b2c3d4e5f60718293a4b5c6d7e8f90' },
      details: { type: 'object', additionalProperties: true },
    },
    example: { error: { code: 'invalid_request', message: 'request validation failed', request_id: 'a1b2c3d4e5f60718293a4b5c6d7e8f90', details: {} } },
  })
  error: { code: string; message: string; request_id?: string; details?: Record<string, any> };
}
