import { Injectable } from '@nestjs/common';
import { randomUUID } from 'crypto';
import { MongoService } from '../mongo.service';
import { cartActiveUsers, SERVICE_VAL } from '../observability/metrics';
import { logger } from '../observability/logger';

const newLineId = (): string => randomUUID().replace(/-/g, '');

@Injectable()
export class CartService {
  constructor(private readonly mongo: MongoService) {}

  private async ensureCart(userId: string): Promise<void> {
    await this.mongo.carts.updateOne({ userId }, { $setOnInsert: { userId, items: [], createdAt: new Date() }, $set: { updatedAt: new Date() } }, { upsert: true });
  }
  private toDoc(doc: any, userId: string): any {
    return { userId, items: (doc?.items || []).map((i: any) => ({ ...i, snapshotAt: i.snapshotAt instanceof Date ? i.snapshotAt.toISOString() : i.snapshotAt })), createdAt: doc?.createdAt, updatedAt: doc?.updatedAt };
  }

  async getCart(userId: string): Promise<any> {
    await this.ensureCart(userId);
    return this.toDoc(await this.mongo.carts.findOne({ userId }), userId);
  }
  async addItem(userId: string, body: any): Promise<any> {
    await this.ensureCart(userId);
    const ex = await this.mongo.carts.findOne({ userId, items: { $elemMatch: { shopId: body.shop_id, variantId: body.variant_id } } });
    if (ex) {
      await this.mongo.carts.updateOne({ userId, 'items.shopId': body.shop_id, 'items.variantId': body.variant_id }, { $inc: { 'items.$.quantity': body.quantity }, $set: { 'items.$.priceStale': true, 'items.$.snapshotAt': new Date(), updatedAt: new Date() } } as any);
    } else {
      const line = { lineId: newLineId(), shopId: body.shop_id, productId: body.product_id, variantId: body.variant_id, quantity: body.quantity, unitPriceMinor: 0, salePriceMinor: null, attributes: body.attributes || {}, snapshotAt: new Date(), priceStale: false };
      await this.mongo.carts.updateOne({ userId }, { $push: { items: line }, $set: { updatedAt: new Date() } } as any, { upsert: true });
    }
    logger.info('cart.api', `cart item added user=${userId} shop=${body.shop_id} variant=${body.variant_id} qty=${body.quantity}`);
    return this.getCart(userId);
  }
  async patchItem(userId: string, id: string, qty: number): Promise<any> {
    if (qty === 0) await this.mongo.carts.updateOne({ userId }, { $pull: { items: { lineId: id } }, $set: { updatedAt: new Date() } } as any);
    else await this.mongo.carts.updateOne({ userId, 'items.lineId': id }, { $set: { 'items.$.quantity': qty, updatedAt: new Date() } } as any);
    return this.getCart(userId);
  }
  async deleteItem(userId: string, id: string): Promise<any> {
    await this.mongo.carts.updateOne({ userId }, { $pull: { items: { lineId: id } }, $set: { updatedAt: new Date() } } as any);
    return this.getCart(userId);
  }
  async clearCart(userId: string): Promise<any> {
    await this.mongo.carts.updateOne({ userId }, { $set: { items: [], updatedAt: new Date() } }, { upsert: true });
    return this.getCart(userId);
  }

  async getWishlist(userId: string): Promise<any> {
    await this.mongo.wishlists.updateOne({ userId }, { $setOnInsert: { userId, items: [] } }, { upsert: true });
    const d = await this.mongo.wishlists.findOne({ userId });
    return { userId, items: (d?.items || []).map((i: any) => ({ ...i, addedAt: i.addedAt instanceof Date ? i.addedAt.toISOString() : i.addedAt })) };
  }
  async addWishlist(userId: string, body: any): Promise<any> {
    await this.getWishlist(userId);
    const ex = await this.mongo.wishlists.findOne({ userId, items: { $elemMatch: { productId: body.product_id, variantId: body.variant_id ?? null } } });
    if (!ex) await this.mongo.wishlists.updateOne({ userId }, { $push: { items: { lineId: newLineId(), productId: body.product_id, variantId: body.variant_id ?? null, addedAt: new Date() } } } as any);
    return this.getWishlist(userId);
  }
  async removeWishlist(userId: string, id: string): Promise<any> {
    await this.mongo.wishlists.updateOne({ userId }, { $pull: { items: { lineId: id } } } as any);
    return this.getWishlist(userId);
  }
}
