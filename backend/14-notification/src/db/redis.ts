// Redis DB 10 — dedup window + WebSocket pod routing + cross-pod pub/sub fan-out.
// DEGRADABLE: Redis is NEVER a /ready gate (architecture §8.1) and a connection
// error must NOT crash the process. We lazyConnect, swallow 'error' events to a
// warning, and the dedup path FAILS OPEN (treats Redis-down as "not a duplicate")
// so an outage degrades to possible-redelivery rather than dropped notifications.
import Redis from 'ioredis';
import { config } from '../config';
import { logger } from '../observability/logger';

// Cross-pod WS broadcast travels over ONE Redis channel; each pod filters by userId.
export const WS_CHANNEL = 'ws:user';

// Payload shape on the WS_CHANNEL pub/sub (documented for the realtime agent):
//   { userId: string; payload: any }
export interface WsBroadcast {
  userId: string;
  payload: any;
}

let client: Redis | null = null;
let subscriber: Redis | null = null;

function build(): Redis {
  const r = new Redis({
    host: config.redisHost,
    port: config.redisPort,
    password: config.redisPassword || undefined,
    db: config.redisDb,
    lazyConnect: true,
    maxRetriesPerRequest: 2,
    enableReadyCheck: true,
    retryStrategy: (times) => Math.min(times * 200, 2000),
  });
  // Swallow errors to a warning — Redis must never crash the process.
  r.on('error', (e: any) => logger.warn('notification.redis', `redis error: ${String(e?.message).slice(0, 80)}`));
  return r;
}

// Best-effort connect (non-fatal). bootstrap() does NOT await readiness as a gate.
export async function connectRedis(): Promise<void> {
  if (client) return;
  client = build();
  try {
    await client.connect();
    logger.info('notification.boot', 'redis connected (db 10)');
  } catch (e: any) {
    logger.warn('notification.boot', `redis connect deferred: ${String(e?.message).slice(0, 80)}`);
  }
}

export function getRedis(): Redis {
  if (!client) throw new Error('redis not initialised');
  return client;
}

// Liveness check for /health ONLY (diagnostic — never the /ready gate). Throws on failure.
export async function ping(): Promise<void> {
  if (!client) throw new Error('redis not initialised');
  await client.ping();
}

// Dedup: SET notif:dedup:<topic>:<key> '1' NX EX ttl.
//   returns true  → newly set (this is the FIRST delivery → process it)
//   returns false → key already present (CONFIRMED duplicate → skip)
// FAILS OPEN: on any Redis error returns true (process the message) so a Redis
// outage degrades to possible-redelivery, never to a dropped notification.
export async function dedupSetNx(topic: string, key: string, ttl = config.notifDedupTtl): Promise<boolean> {
  if (!client) return true;
  try {
    const res = await client.set(`notif:dedup:${topic}:${key}`, '1', 'EX', ttl, 'NX');
    return res === 'OK';
  } catch (e: any) {
    logger.warn('notification.redis', `dedup degraded (fail-open): ${String(e?.message).slice(0, 60)}`);
    return true;
  }
}

// WS routing: map a connected user -> the pod id holding their socket (session TTL).
export async function setWsUserPod(userId: string, podId: string, ttlSeconds = 3600): Promise<void> {
  if (!client) return;
  try { await client.set(`ws:user:${userId}`, podId, 'EX', ttlSeconds); } catch { /* degrade */ }
}
export async function getWsUserPod(userId: string): Promise<string | null> {
  if (!client) return null;
  try { return await client.get(`ws:user:${userId}`); } catch { return null; }
}

// Cross-pod fan-out: publish a WS event so the pod holding the user's socket (which
// may be a different pod than the consumer) can push it. Best-effort.
export async function publishWsEvent(userId: string, payload: any): Promise<void> {
  if (!client) return;
  try { await client.publish(WS_CHANNEL, JSON.stringify({ userId, payload } as WsBroadcast)); } catch { /* degrade */ }
}

// Subscribe to the cross-pod WS channel. Uses a DEDICATED duplicated connection —
// a subscribed ioredis client cannot run normal commands. handler receives the
// parsed { userId, payload }; the realtime layer filters to its locally-held sockets.
export async function subscribeWsEvents(handler: (msg: WsBroadcast) => void): Promise<void> {
  if (!client) return;
  if (!subscriber) {
    subscriber = client.duplicate();
    subscriber.on('error', (e: any) => logger.warn('notification.redis', `ws subscriber error: ${String(e?.message).slice(0, 80)}`));
  }
  await subscriber.subscribe(WS_CHANNEL);
  subscriber.on('message', (_channel, raw) => {
    try { handler(JSON.parse(raw) as WsBroadcast); } catch { /* drop malformed */ }
  });
}

export async function closeRedis(): Promise<void> {
  try { await subscriber?.quit(); } catch { /* ignore */ }
  try { await client?.quit(); } catch { /* ignore */ }
  subscriber = null;
  client = null;
}
