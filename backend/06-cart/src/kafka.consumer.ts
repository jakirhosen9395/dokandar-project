import { Kafka } from 'kafkajs';
import { MongoClient, Db } from 'mongodb';
import { config } from './config';
import { logger } from './observability/logger';

let db: Db | null = null;
async function getDb(): Promise<Db | null> {
  if (db) return db;
  if (!config.mongoUrl) return null;
  try { const c = await MongoClient.connect(config.mongoUrl, { serverSelectionTimeoutMS: 5000 } as any); db = c.db(config.mongoDb); return db; } catch { return null; }
}

export function startConsumers(): void {
  if (!config.kafkaBootstrap) return;
  const kafka = new Kafka({ clientId: 'cart', brokers: [config.kafkaBootstrap], retry: { retries: 8, initialRetryTime: 1000 } });
  const topics: Array<[string, 'product' | 'order']> = [[config.kafkaTopicProductChanged, 'product'], [config.kafkaTopicOrderPlaced, 'order']];
  for (const [topic, kind] of topics) {
    if (!topic) continue;
    const consumer = kafka.consumer({ groupId: `${config.kafkaGroupPrefix}-${kind}` });
    (async () => {
      try {
        await consumer.connect();
        await consumer.subscribe({ topic, fromBeginning: false });
        logger.info('cart.consumer', `consuming ${topic} (group=${config.kafkaGroupPrefix}-${kind})`);
        await consumer.run({
          eachMessage: async ({ message }) => {
            try {
              const v = JSON.parse(message.value?.toString() || '{}');
              if (kind === 'product') await onProduct(v); else await onOrder(v);
            } catch (e: any) { logger.warn('cart.consumer', `${kind}: bad message: ${e?.message}`); }
          },
        });
      } catch (e: any) { logger.warn('cart.consumer', `${kind} consumer failed: ${e?.message}`); }
    })();
  }
}

async function onProduct(v: any): Promise<void> {
  const pid = v.product_id; if (!pid) return;
  const d = await getDb(); if (!d) return;
  await d.collection('carts').updateMany({ 'items.productId': pid }, { $set: { 'items.$[e].priceStale': true, updatedAt: new Date() } }, { arrayFilters: [{ 'e.productId': pid }] }).catch(() => {});
  logger.info('cart.consumer', `price_stale flagged for product=${pid}`);
}
async function onOrder(v: any): Promise<void> {
  const userId = v.user_id || v.customer_id; const shopIds: string[] = v.shop_ids || (v.sub_orders || []).map((s: any) => s.shop_id) || [];
  if (!userId || shopIds.length === 0) return;
  const d = await getDb(); if (!d) return;
  await d.collection('carts').updateOne({ userId: String(userId) }, { $pull: { items: { shopId: { $in: shopIds } } }, $set: { updatedAt: new Date() } } as any).catch(() => {});
  logger.info('cart.consumer', `cleared ordered shop lines user=${userId}`);
}
