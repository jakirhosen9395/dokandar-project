// MongoDB — the inbox store (the ONLY /ready gate for 14-notification; there is no
// Postgres and no outbox). Raw mongodb driver, singleton client. ensureDb() creates
// the three collections (idempotently) and ensures the indexes, including the
// 90-day TTL on notification_dispatch_log.tsDate — which MUST be a real BSON Date
// (NOT a string) or Mongo's TTL monitor silently never expires the rows.
import { Collection, Db, MongoClient } from 'mongodb';
import { config } from '../config';
import { logger } from '../observability/logger';
import type { DispatchLogEntry, Notification, Preferences } from '../types';

let client: MongoClient | null = null;
let db: Db | null = null;

const DISPATCH_TTL_SECONDS = 7776000; // 90 days

// Connect the singleton client + ensure the database/collections/indexes. Awaited
// in bootstrap() BEFORE app.listen — Mongo is the readiness gate, so a failure here
// must surface (the caller decides whether to retry/exit).
export async function connectMongo(): Promise<void> {
  if (client) return;
  client = await MongoClient.connect(config.mongoUri, { serverSelectionTimeoutMS: 8000 } as any);
  db = client.db(config.mongoDb);
  await ensureDb();
  logger.info('notification.boot', 'mongo connected; collections + indexes ensured');
}

// Idempotent: createCollection throws NamespaceExists and createIndex can throw
// IndexOptionsConflict when re-run against an existing store — both are swallowed.
async function ensureDb(): Promise<void> {
  const d = db!;
  for (const name of ['notifications', 'notification_preferences', 'notification_dispatch_log']) {
    await d.createCollection(name).catch(() => {});
  }
  // notifications — latest-N-per-user inbox read path.
  await d.collection('notifications').createIndex({ userId: 1, createdAt: -1 }).catch(() => {});
  // notification_preferences — one doc per user.
  await d.collection('notification_preferences').createIndex({ userId: 1 }, { unique: true }).catch(() => {});
  // notification_dispatch_log — 90-day TTL on the BSON-Date tsDate (NOT a string).
  await d.collection('notification_dispatch_log')
    .createIndex({ tsDate: 1 }, { expireAfterSeconds: DISPATCH_TTL_SECONDS })
    .catch(() => {});
}

export function getDb(): Db {
  if (!db) throw new Error('mongo not connected');
  return db;
}

// Liveness check for /ready (the gate) and /health (diagnostic). Throws on failure.
export async function ping(): Promise<void> {
  if (!db) throw new Error('mongo not connected');
  await db.command({ ping: 1 });
}

// Typed collection getters.
export function notifications(): Collection<Notification> {
  return getDb().collection<Notification>('notifications');
}
export function preferences(): Collection<Preferences> {
  return getDb().collection<Preferences>('notification_preferences');
}
export function dispatchLog(): Collection<DispatchLogEntry> {
  return getDb().collection<DispatchLogEntry>('notification_dispatch_log');
}

export async function closeMongo(): Promise<void> {
  await client?.close().catch(() => {});
  client = null;
  db = null;
}
