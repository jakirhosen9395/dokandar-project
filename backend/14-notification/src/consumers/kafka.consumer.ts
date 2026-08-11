// Kafka consumer (architecture §4.1, §10, §16-e). The hot path of the service:
//   consume → dedup (Redis 24h) → materialize the MongoDB inbox row → realtime push
//   (NATS subject + cross-pod Redis broadcast) → fan out to the opted-in RabbitMQ
//   channel queues → COMMIT-AFTER-HANDLE.
//
// Terminal consumer: it emits NOTHING to Kafka (no outbox). Offsets are committed
// MANUALLY and ONLY after the handler's work succeeds (autoCommit:false) — a throw
// leaves the offset uncommitted so the message redelivers, and the 24h dedup window
// makes that at-least-once delivery effectively-once.
//
// DEGRADABLE: a Kafka outage at boot is non-fatal (server.ts wraps startConsumers in
// try/catch); we also self-heal on a consumer crash. Redis dedup fails OPEN (a Redis
// outage degrades to possible-redelivery, never a dropped notification). The realtime
// push + channel dispatch are best-effort — losing either never blocks the commit, as
// the inbox row is the durable record.
import { Kafka, logLevel } from 'kafkajs';
import { config } from '../config';
import { logger } from '../observability/logger';
import { notifications, preferences } from '../db/mongo';
import { dedupSetNx, publishWsEvent } from '../db/redis';
import { publishInbox } from '../realtime/nats';
import { incDedup } from '../observability/metrics';
import { mapEvent, EventKind } from '../messaging/event-mapper';
import type { Channel as PrefChannel } from '../types';

// Configured topic name → the logical event kind (so renaming a topic in env can never
// break the mapper). Built once from config.
const TOPIC_KIND: Record<string, EventKind> = {
  [config.kafkaTopicUserCreated]: 'user.created',
  [config.kafkaTopicOrderPlaced]: 'order.placed',
  [config.kafkaTopicPaymentSettled]: 'payment.settled',
  [config.kafkaTopicKycApproved]: 'kyc.approved',
  [config.kafkaTopicKycRejected]: 'kyc.rejected',
  [config.kafkaTopicWalletCashback]: 'wallet.cashback_granted',
};
const TOPICS = Object.keys(TOPIC_KIND).filter(Boolean);
const ALL_CHANNELS: PrefChannel[] = ['sms', 'push', 'email', 'whatsapp'];
const DEFAULT_CHANNELS = { sms: true, push: true, email: true, whatsapp: true };

let started = false;
let consumer: ReturnType<Kafka['consumer']> | null = null;

async function handleOne(topic: string, value: Buffer | null): Promise<void> {
  const kind = TOPIC_KIND[topic];
  if (!kind) return; // not a subscribed topic (defensive)

  let parsed: any;
  try {
    parsed = value ? JSON.parse(value.toString()) : null;
  } catch {
    logger.warn('notification.consume', `unparseable payload on ${topic} — skipping`);
    return;
  }

  const mapped = mapEvent(kind, parsed);
  if (!mapped) return; // unattributable / irrelevant → skip (commit advances past it)

  // Dedup BEFORE any write. true → first delivery (process); false → confirmed duplicate.
  const fresh = await dedupSetNx(topic, mapped.dedupKey);
  if (!fresh) {
    incDedup();
    return;
  }

  // Materialize the durable inbox row.
  const createdAt = new Date();
  const doc = {
    userId: mapped.userId,
    kind: mapped.draft.kind,
    category: mapped.draft.category,
    title_bn: mapped.draft.title_bn,
    title_en: mapped.draft.title_en,
    body_bn: mapped.draft.body_bn,
    body_en: mapped.draft.body_en,
    deepLink: mapped.draft.deepLink,
    read: false,
    createdAt,
  };
  const ins = await notifications().insertOne(doc as any);

  // Realtime push — publish to BOTH paths (NATS per-user subject + Redis cross-pod
  // broadcast); ws.ts de-dupes per socket on the `id`. Both are best-effort no-ops when
  // the broker is down. NO body is logged.
  const realtime = { id: String(ins.insertedId), ...doc };
  publishInbox(mapped.userId, realtime);
  await publishWsEvent(mapped.userId, realtime);

  // Channel fan-out to the user's opted-in channels (default all-on). Best-effort:
  // enqueueChannel fails open, so a RabbitMQ outage never blocks the commit.
  let channels: Record<string, boolean> = DEFAULT_CHANNELS;
  try {
    const pref = await preferences().findOne({ userId: mapped.userId });
    if (pref?.channels) channels = pref.channels as any;
  } catch { /* prefs read failed → default all-on */ }
  for (const c of ALL_CHANNELS) {
    if (channels[c]) {
      await enqueueSafe(c, { userId: mapped.userId, kind: doc.kind, channel: c, notifId: String(ins.insertedId) });
    }
  }

  logger.info('notification.consume', `materialized kind=${doc.kind} topic=${topic}`); // no body / no PII
}

// Lazily import the worker's enqueue to avoid a static import cycle (consumer ↔ worker).
async function enqueueSafe(channel: PrefChannel, msg: any): Promise<void> {
  try {
    const { enqueueChannel } = await import('../channels/rabbitmq.worker');
    await enqueueChannel(channel, msg);
  } catch (e: any) {
    logger.warn('notification.consume', `channel enqueue degraded: ${String(e?.message).slice(0, 60)}`);
  }
}

async function run(): Promise<void> {
  const kafka = new Kafka({
    clientId: config.serviceName,
    brokers: (config.kafkaBootstrap || '').split(',').map((s) => s.trim()).filter(Boolean),
    logLevel: logLevel.NOTHING,
    retry: { retries: 8, initialRetryTime: 300 },
  });
  consumer = kafka.consumer({ groupId: config.kafkaGroup });

  // Self-heal: on a non-retriable crash, rebuild the consumer after a short backoff.
  consumer.on(consumer.events.CRASH, (e: any) => {
    logger.warn('notification.kafka', `consumer crashed: ${String(e?.payload?.error?.message).slice(0, 80)} — restarting in 5s`);
    started = false;
    consumer = null;
    setTimeout(() => { void startConsumers(); }, 5000);
  });

  await consumer.connect();
  for (const t of TOPICS) {
    await consumer.subscribe({ topic: t, fromBeginning: false });
  }

  await consumer.run({
    autoCommit: false, // COMMIT-AFTER-HANDLE — we own the commit, only after success.
    eachMessage: async ({ topic, partition, message }) => {
      await handleOne(topic, message.value);
      // Commit the NEXT offset only after the handler fully succeeded. A throw above
      // skips this line → the message redelivers → dedup absorbs it.
      await consumer!.commitOffsets([
        { topic, partition, offset: (Number(message.offset) + 1).toString() },
      ]);
    },
  });
  logger.info('notification.boot', `kafka consumer running group=${config.kafkaGroup} topics=${TOPICS.length}`);
}

// Best-effort start (never fatal). Self-heals on connect failure + crash.
export async function startConsumers(): Promise<void> {
  if (started) return;
  started = true;
  if (!config.kafkaBootstrap || TOPICS.length === 0) {
    logger.warn('notification.boot', 'KAFKA_BOOTSTRAP empty or no topics — consumer disabled');
    return;
  }
  try {
    await run();
  } catch (e: any) {
    logger.warn('notification.boot', `kafka consumer init deferred: ${String(e?.message).slice(0, 80)} — retrying in 5s`);
    started = false;
    consumer = null;
    setTimeout(() => { void startConsumers(); }, 5000);
  }
}

export async function stopConsumers(): Promise<void> {
  try { await consumer?.disconnect(); } catch { /* ignore */ }
  consumer = null;
  started = false;
}
