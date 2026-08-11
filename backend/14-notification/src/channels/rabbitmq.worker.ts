// RabbitMQ channel dispatch (architecture §4.2, §10, §13). Four durable per-channel
// queues — notifications.{email,sms,push,whatsapp_deeplink} — each with a bound DLQ,
// plus the notifications.otp.send drain from 01-auth. Each queue is consumed, the
// message stub-dispatched to its provider, audited in notification_dispatch_log
// (90-day TTL), and acked. A dispatch failure NACKs to the DLQ for SRE triage.
//
// DEGRADABLE & SELF-HEALING: RabbitMQ is never a /ready gate. A broker outage is
// logged and a reconnect is scheduled; enqueueChannel() fails open (returns false,
// never throws) so the Kafka consumer still commits — the inbox row + the realtime WS
// push already happened; channel dispatch catches up when the broker returns (KEDA
// scales on the queue depth this module reports).
//
// PRIVACY: OTP codes and notification bodies are NEVER logged and NEVER written to the
// dispatch log — only the channel, provider, an opaque provider id, and the status.
import amqp from 'amqplib';
import type { Channel, ConsumeMessage } from 'amqplib';
import apm from '../apm';
import { config } from '../config';
import { logger } from '../observability/logger';
import { dispatchLog } from '../db/mongo';
import { incSent, setChannelQueueDepth } from '../observability/metrics';
import type { Channel as PrefChannel } from '../types';

// The RabbitMQ topology (the four channel queues + their .dlq, the notifications.dlx
// dead-letter exchange, and notifications.otp.send + its .dlq) is PRE-PROVISIONED by the
// infra (01-auth declares otp.send). This worker CONSUMES that topology as-is and never
// re-declares it: re-asserting a queue with different arguments raises 406
// PRECONDITION-FAILED and closes the channel (the bug this version fixes).

// preference channel → its RabbitMQ queue + provider id (note: whatsapp → whatsapp_deeplink).
const CHANNEL_QUEUE: Record<PrefChannel, { queue: string; provider: string }> = {
  sms: { queue: 'notifications.sms', provider: 'ssl_wireless' },
  push: { queue: 'notifications.push', provider: 'fcm' },
  email: { queue: 'notifications.email', provider: 'amazon_ses' },
  whatsapp: { queue: 'notifications.whatsapp_deeplink', provider: 'whatsapp_cloud' },
};

// queue name → {channel,provider} for the consume side (dispatch log + depth gauge).
function queueMeta(queue: string): { channel: PrefChannel; provider: string } {
  switch (queue) {
    case 'notifications.sms': return { channel: 'sms', provider: 'ssl_wireless' };
    case 'notifications.push': return { channel: 'push', provider: 'fcm' };
    case 'notifications.email': return { channel: 'email', provider: 'amazon_ses' };
    case 'notifications.whatsapp_deeplink': return { channel: 'whatsapp', provider: 'whatsapp_cloud' };
    default: return { channel: 'sms', provider: 'unknown' };
  }
}

let conn: any = null;
let ch: Channel | null = null;
let monitorCh: Channel | null = null;
let started = false;
let depthTimer: ReturnType<typeof setInterval> | null = null;
let reconnecting = false;

// The business channel queues (env-driven) + the OTP drain queue.
function businessQueues(): string[] {
  return config.rabbitmqQueues && config.rabbitmqQueues.length
    ? config.rabbitmqQueues
    : ['notifications.email', 'notifications.sms', 'notifications.push', 'notifications.whatsapp_deeplink'];
}

// Publish a dispatch command for one channel. FAILS OPEN: returns false (never throws)
// when the broker is absent/down — the caller (Kafka consumer) treats channel dispatch
// as best-effort and commits regardless (the inbox row is already durable).
export async function enqueueChannel(channel: PrefChannel, msg: any): Promise<boolean> {
  if (!ch) return false;
  const q = CHANNEL_QUEUE[channel]?.queue;
  if (!q) return false;
  try {
    return ch.sendToQueue(q, Buffer.from(JSON.stringify(msg)), { persistent: true, contentType: 'application/json' });
  } catch (e: any) {
    logger.warn('notification.rabbitmq', `enqueue ${channel} degraded: ${String(e?.message).slice(0, 60)}`);
    return false;
  }
}

// Stub provider dispatch for a business-channel message. NO body/PII is logged.
async function dispatchBusiness(queue: string, raw: ConsumeMessage): Promise<void> {
  const { channel, provider } = queueMeta(queue);
  let userId = 'unknown';
  let notifId = '';
  try {
    const m = JSON.parse(raw.content.toString());
    if (m && typeof m === 'object') {
      if (typeof m.userId === 'string') userId = m.userId;
      if (typeof m.notifId === 'string') notifId = m.notifId;
    }
  } catch { /* unparseable → still record the attempt below, no content logged */ }

  // (stub) deliver to the provider here. We only record the audit row — never the body.
  const providerId = `stub:${channel}:${notifId || raw.fields.deliveryTag}`;
  await dispatchLog().insertOne({
    userId,
    channel,
    provider,
    providerId,
    status: 'sent',
    tsDate: new Date(), // BSON Date → the 90-day TTL index actually expires it
  });
  incSent(channel);
  logger.info('notification.dispatch', `dispatched channel=${channel} provider=${provider}`); // no body / no PII
}

// OTP drain (architecture §4.2). The OTP code is NEVER logged and NEVER stored.
async function dispatchOtp(raw: ConsumeMessage): Promise<void> {
  let userId = 'otp';
  try {
    const m = JSON.parse(raw.content.toString());
    // accept a user ref if present; the phone + code are deliberately ignored for logging.
    if (m && typeof m === 'object' && typeof m.user_id === 'string') userId = m.user_id;
  } catch { /* unparseable OTP payload — record the attempt, never the content */ }
  // (stub) send the OTP SMS via the primary provider.
  await dispatchLog().insertOne({
    userId,
    channel: 'sms',
    provider: 'ssl_wireless',
    providerId: `otp:${raw.fields.deliveryTag}`,
    status: 'sent',
    tsDate: new Date(),
  });
  incSent('sms');
  logger.info('notification.dispatch', 'otp delivered'); // NEVER the code or phone
}

// Passive existence probe on a THROWAWAY channel — a missing queue (404 NOT_FOUND) closes
// only the probe channel, never the consume channel, so one absent queue can't abort the
// rest. checkQueue is passive: it NEVER 406s on an argument mismatch (unlike assertQueue).
async function queueExists(queue: string): Promise<boolean> {
  let probe: Channel | null = null;
  try {
    probe = await conn.createChannel();
    await probe.checkQueue(queue);
    return true;
  } catch {
    return false;
  } finally {
    try { await probe?.close(); } catch { /* already closed by the 404 */ }
  }
}

async function setup(): Promise<void> {
  conn = await amqp.connect(config.rabbitmqUrl);
  conn.on('error', (e: any) => logger.warn('notification.rabbitmq', `conn error: ${String(e?.message).slice(0, 80)}`));
  conn.on('close', () => { scheduleReconnect('connection closed'); });

  ch = await conn.createChannel();
  await ch.prefetch(20);

  const queues = businessQueues();
  const otpQ = config.rabbitmqQueueOtp || 'notifications.otp.send';

  // CONSUME the pre-provisioned queues (no assert/declare). A failed dispatch nacks
  // (requeue:false) → the queue's own dead-letter config (infra-owned) routes it to its DLQ.
  const consuming: string[] = [];
  for (const q of queues) {
    if (!(await queueExists(q))) { logger.warn('notification.rabbitmq', `queue ${q} absent — skipping`); continue; }
    await ch.consume(q, (raw) => {
      if (!raw) return;
      // amqplib is not auto-instrumented — open an APM transaction per message so the consume
      // shows in APM (RabbitMQ as a messaging source) and the dispatch spans/logs correlate.
      const tx = apm.startTransaction(`RabbitMQ RECEIVE from ${q}`, 'messaging');
      dispatchBusiness(q, raw)
        .then(() => ch && ch.ack(raw))
        .catch((e: any) => {
          logger.warn('notification.rabbitmq', `dispatch failed q=${q} → DLQ: ${String(e?.message).slice(0, 60)}`);
          try { ch && ch.nack(raw, false, false); } catch { /* channel gone */ }
        })
        .finally(() => { if (tx) tx.end(); });
    });
    consuming.push(q);
  }

  // OTP drain — GATED. In dev/stage, 00-support is the SMS-carrier mock that drains this
  // queue (and exposes /otp/latest); 14 must NOT compete with it. Only drain in prod.
  if (!config.otpDrainEnabled) {
    logger.info('notification.boot', `OTP drain DISABLED (APP_ENV=${config.appEnv}) — 00-support is the SMS-carrier mock that consumes ${otpQ}`);
  } else if (await queueExists(otpQ)) {
    await ch.consume(otpQ, (raw) => {
      if (!raw) return;
      const tx = apm.startTransaction(`RabbitMQ RECEIVE from ${otpQ}`, 'messaging');
      dispatchOtp(raw)
        .then(() => ch && ch.ack(raw))
        .catch((e: any) => {
          logger.warn('notification.rabbitmq', `otp dispatch failed → DLQ: ${String(e?.message).slice(0, 60)}`);
          try { ch && ch.nack(raw, false, false); } catch { /* channel gone */ }
        })
        .finally(() => { if (tx) tx.end(); });
    });
  } else {
    logger.warn('notification.rabbitmq', `otp queue ${otpQ} absent — skipping`);
  }

  // A dedicated channel for the queue-depth gauge so a checkQueue error never disturbs
  // the consume channel.
  monitorCh = await conn.createChannel();
  startDepthGauge(consuming);

  logger.info('notification.boot', `rabbitmq channel workers consuming ${consuming.length} queues + otp drain`);
}

function startDepthGauge(queues: string[]): void {
  if (depthTimer) clearInterval(depthTimer);
  const tick = async () => {
    if (!monitorCh) return;
    for (const q of queues) {
      try {
        const info = await monitorCh.checkQueue(q);
        setChannelQueueDepth(queueMeta(q).channel, info.messageCount);
      } catch { /* queue absent / channel hiccup — skip this tick */ }
    }
  };
  depthTimer = setInterval(() => { void tick(); }, 10000);
  void tick();
}

function scheduleReconnect(why: string): void {
  if (reconnecting) return;
  reconnecting = true;
  ch = null;
  monitorCh = null;
  conn = null;
  if (depthTimer) { clearInterval(depthTimer); depthTimer = null; }
  logger.warn('notification.rabbitmq', `reconnecting in 3s (${why})`);
  setTimeout(() => {
    reconnecting = false;
    setup().catch((e: any) => scheduleReconnect(`retry failed: ${String(e?.message).slice(0, 60)}`));
  }, 3000);
}

// Best-effort start (never fatal). server.ts wraps this in try/catch; we ALSO self-heal
// so a broker that is briefly unavailable at boot recovers without a restart.
export async function startChannelWorkers(): Promise<void> {
  if (started) return;
  started = true;
  if (!config.rabbitmqUrl) {
    logger.warn('notification.boot', 'RABBITMQ_URL empty — channel dispatch disabled');
    return;
  }
  try {
    await setup();
  } catch (e: any) {
    logger.warn('notification.boot', `rabbitmq init deferred: ${String(e?.message).slice(0, 80)}`);
    scheduleReconnect('initial connect failed');
  }
}
