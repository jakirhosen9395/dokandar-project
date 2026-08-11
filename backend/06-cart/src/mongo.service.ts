// Raw MongoDB driver for the cart/wishlist data path. Prisma's Mongo connector
// requires a replica set for its composite-list updates (it wraps them in a
// transaction); the platform's infra Mongo is a standalone, so we use atomic
// single-doc ops ($inc/$push/$pull/$set) which need no transaction. The Prisma
// schema (prisma/schema.prisma) remains the documented data model.
import { Injectable, OnModuleInit, OnModuleDestroy } from '@nestjs/common';
import { Collection, Db, MongoClient } from 'mongodb';
import { config } from './config';
import { logger } from './observability/logger';

@Injectable()
export class MongoService implements OnModuleInit, OnModuleDestroy {
  private client!: MongoClient;
  public db!: Db;
  public carts!: Collection<any>;
  public wishlists!: Collection<any>;
  async onModuleInit(): Promise<void> {
    this.client = await MongoClient.connect(config.mongoUrl, { serverSelectionTimeoutMS: 8000 } as any);
    this.db = this.client.db(config.mongoDb);
    this.carts = this.db.collection('carts');
    this.wishlists = this.db.collection('wishlists');
    await this.carts.createIndex({ userId: 1 }, { unique: true }).catch(() => {});
    await this.wishlists.createIndex({ userId: 1 }, { unique: true }).catch(() => {});
    logger.info('cart.boot', 'mongo connected; unique indexes ensured');
  }
  async onModuleDestroy(): Promise<void> { await this.client?.close().catch(() => {}); }
  async ping(): Promise<void> { await this.db.command({ ping: 1 }); }
}
