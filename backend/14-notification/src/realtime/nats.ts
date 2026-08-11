// NATS — the low-latency realtime WS fan-out layer (architecture §3.3, §4.1, §16-i).
//
// NATS is NOT a durability path: the durable notification record is the MongoDB
// inbox row (db/mongo.ts). NATS only carries the in-flight realtime push to the
// WebSocket pods, so the outbox rules do NOT apply here. A NATS outage degrades
// realtime push ONLY — the inbox still materializes and the channel workers still
// dispatch. Therefore EVERY function here tolerates NATS being absent or down:
// connect failure is logged and swallowed (non-fatal), and publish/subscribe
// no-op safely when there is no connection.
//
// We use a plain CORE NATS pub/sub on the per-user subject (JetStream is optional
// and deliberately NOT used — there is nothing to make durable; the inbox row is
// the system of record). The subject is `<NATS_WS_SUBJECT_PREFIX>.<userId>` so a
// subscriber for one user never sees another user's traffic (owner scoping).
import { connect, ConnectionOptions, NatsConnection, StringCodec, Subscription } from 'nats';
import apm from '../apm';
import { config } from '../config';
import { logger } from '../observability/logger';

// JSON travels as a string payload on the wire (NATS is payload-agnostic).
const sc = StringCodec();

// Parse NATS_URL into a server address + auth. The infra uses TOKEN auth
// (nats://<token>@host:4222) — nats.js treats bare userinfo as a USERNAME (→
// "Authorization Violation"), so we must lift the token into the `token` option.
// A userinfo containing ':' is treated as user:pass instead.
function natsOptions(url: string): ConnectionOptions {
  const base: ConnectionOptions = {
    name: config.serviceName,
    reconnect: true,
    maxReconnectAttempts: -1,   // reconnect forever; realtime recovers on its own
    reconnectTimeWait: 2000,
    timeout: 5000,
  };
  const m = /^nats:\/\/([^@/]+)@(.+)$/.exec(url);
  if (!m) return { ...base, servers: url };
  const userinfo = decodeURIComponent(m[1]);
  const server = `nats://${m[2]}`;
  if (userinfo.includes(':')) {
    const [user, pass] = userinfo.split(':');
    return { ...base, servers: server, user, pass };
  }
  return { ...base, servers: server, token: userinfo };
}

let nc: NatsConnection | null = null;
let connecting: Promise<void> | null = null;

// NATS subject tokens cannot contain spaces or the reserved chars `.`, `*`, `>`.
// Opaque user ids are normally UUIDs/digits, but we defensively sanitize so a
// malformed id can never widen a subscription into a wildcard or split a subject.
function subjectFor(userId: string): string {
  const safe = String(userId).replace(/[.*>\s]/g, '_');
  return `${config.natsSubjectPrefix}.${safe}`;
}

// Best-effort connect (non-fatal). server.ts calls this inside a try/catch and
// NEVER blocks listen on it; even so we never throw — realtime is degradable.
export async function connectNats(): Promise<void> {
  if (nc) return;
  if (!config.natsUrl) {
    logger.warn('notification.boot', 'NATS_URL empty — realtime WS push degraded (inbox unaffected)');
    return;
  }
  if (connecting) return connecting;
  connecting = (async () => {
    try {
      nc = await connect(natsOptions(config.natsUrl));
      logger.info('notification.boot', 'nats connected (realtime WS fan-out)');
      // Surface (but never crash on) async connection errors / closure.
      (async () => {
        try {
          for await (const s of nc!.status()) {
            if (s.type === 'disconnect' || s.type === 'error') {
              logger.warn('notification.nats', `nats ${s.type}: ${String((s as any).data).slice(0, 80)}`);
            }
          }
        } catch { /* status iterator ended — connection closed */ }
      })();
      nc.closed().then((err) => {
        if (err) logger.warn('notification.nats', `nats connection closed: ${String((err as any)?.message).slice(0, 80)}`);
        nc = null;
      }).catch(() => { nc = null; });
    } catch (e: any) {
      // Connect failure is NON-FATAL: log and continue with realtime degraded.
      logger.warn('notification.boot', `nats connect failed (realtime degraded): ${String(e?.message).slice(0, 100)}`);
      nc = null;
    } finally {
      connecting = null;
    }
  })();
  return connecting;
}

// Publish a freshly-materialized notification to the user's realtime subject so any
// WS pod subscribed for that user pushes it. No-op (safe) when NATS is absent/down —
// the inbox row is already durable in Mongo, so a dropped push is only a missed
// realtime nudge, never a lost notification. Never throws.
export function publishInbox(userId: string, notification: any): void {
  if (!nc) return;
  // nats is not auto-instrumented — emit an exit span with a friendly "nats" target so NATS
  // shows in Dependencies + the service map (this runs inside the Kafka-consumer transaction).
  const span: any = apm.startSpan('NATS publish inbox', 'messaging', 'nats', 'send', { exitSpan: true } as any);
  if (span && typeof span.setServiceTarget === 'function') span.setServiceTarget('messaging', 'nats');
  try {
    nc.publish(subjectFor(userId), sc.encode(JSON.stringify(notification)));
  } catch (e: any) {
    logger.warn('notification.nats', `publishInbox degraded: ${String(e?.message).slice(0, 80)}`);
  } finally {
    if (span) span.end();
  }
}

// Subscribe a live WS socket to its user's realtime subject. Returns an unsubscribe
// function (always safe to call, even when NATS is absent — then it's a no-op). The
// handler receives the decoded notification object; malformed payloads are dropped.
// Never throws: a NATS outage must not crash the socket handler.
export function subscribeInbox(userId: string, handler: (notification: any) => void): () => void {
  if (!nc) return () => { /* no-op: realtime degraded, inbox still durable */ };
  let sub: Subscription | null = null;
  try {
    sub = nc.subscribe(subjectFor(userId));
  } catch (e: any) {
    logger.warn('notification.nats', `subscribeInbox failed: ${String(e?.message).slice(0, 80)}`);
    return () => { /* no-op */ };
  }
  const s = sub;
  // Drive the async iterator off-thread; iteration ends when unsubscribe()/drain()
  // is called or the connection closes. Any error ends the loop without crashing.
  (async () => {
    try {
      for await (const m of s) {
        try { handler(JSON.parse(sc.decode(m.data))); } catch { /* drop malformed */ }
      }
    } catch { /* subscription ended (unsubscribe/close) — normal */ }
  })();
  return () => {
    try { s.unsubscribe(); } catch { /* already gone */ }
  };
}

// Graceful drain on shutdown (best-effort). server.ts closes redis+mongo on SIGTERM;
// the NATS connection otherwise tears down with the process — this just lets in-flight
// publishes flush if invoked.
export async function closeNats(): Promise<void> {
  const c = nc;
  nc = null;
  if (!c) return;
  try { await c.drain(); } catch { try { await c.close(); } catch { /* ignore */ } }
}
