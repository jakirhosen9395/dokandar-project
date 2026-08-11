// Realtime inbox WebSocket (architecture §5, §3.2, §3.3). Fastify plugin mounted at
// prefix /api/v1/notification → effective route GET /api/v1/notification/ws/inbox.
// Uses the @fastify/websocket plugin already registered at the root in server.ts.
//
// Fan-out reaches a live socket via TWO independent paths so an inbox event published
// by ANY pod is delivered regardless of which pod holds the socket:
//   1. NATS subject `<prefix>.<userId>` — subscribed PER SOCKET (subjects are per-user).
//   2. Redis cross-pod pub/sub on WS_CHANNEL — ONE process-wide subscriber that
//      dispatches to a local registry of sockets keyed by userId.
// Because the consumer publishes to BOTH paths, the same event can arrive twice; we
// de-dupe per socket on a stable event id (the notification's _id/createdAt) so it is
// sent to the client at most once.
//
// DEGRADABLE: a NATS or Redis outage must NOT crash the socket handler. Realtime then
// degrades to "no live push" while the inbox row stays durable in MongoDB and the REST
// inbox keeps serving. The handler only ever throws back a clean 1008/1011 close.
//
// SECURITY: the Bearer is verified on upgrade (header OR ?token= for browsers that
// cannot set WS headers); the socket is owner-scoped to its JWT subject; it only ever
// receives that user's own notifications. No PII beyond the user's own inbox rows.
import { FastifyInstance, FastifyPluginOptions, FastifyReply, FastifyRequest } from 'fastify';
import apm from '../apm';
import { verifyToken, getUserId } from '../auth/jwt';
import { buildEnvelope } from '../common/errors';
import { logger } from '../observability/logger';
import { wsConnInc, wsConnDec } from '../observability/metrics';
import { subscribeInbox } from './nats';
import {
  WsBroadcast,
  setWsUserPod,
  subscribeWsEvents,
} from '../db/redis';

// ws.WebSocket readyState OPEN. Avoids importing the 'ws' types at runtime.
const WS_OPEN = 1;
// RFC 6455 close code used on auth failure (policy violation).
const CLOSE_POLICY = 1008;

// OpenAPI schema for the WS upgrade. architecture §6 requires the route to APPEAR in
// the spec ("the WS upgrade is documented as a non-2xx-bodied endpoint") and the global
// contract requires every served route to be in /openapi.json — so it is NOT hidden.
// It is a GET that upgrades to a WebSocket; there is no 2xx JSON body, only the 401 the
// upgrade fails with when the Bearer is missing/invalid (closed with code 1008).
const wsInboxSchema = {
  tags: ['realtime'],
  operationId: 'streamInbox',
  summary: 'Realtime inbox WebSocket stream',
  description:
    'WebSocket upgrade (GET → 101). Authenticates the Bearer on upgrade (Authorization header or ?token= for browsers), registers ws:user:<id> → pod, and pushes the owner-scoped inbox stream via NATS + the cross-pod Redis broadcast. Frames: a `hello` ack on connect, then `{type:"inbox",notification:{…}}` per event. A missing/invalid token closes the socket with code 1008 (documented here as 401). Non-2xx-bodied endpoint.',
  security: [{ bearerJwt: [] }],
  querystring: {
    type: 'object',
    properties: { token: { type: 'string', description: 'RS256 JWT, for clients that cannot set the Authorization header on a WS upgrade' } },
  },
  response: {
    // Shared ErrorEnvelope component (defined in server.ts). $ref is safe here: server.ts
    // overrides the serializer compiler with a plain pretty-stringify, so the response
    // schema is documentation-only and the $ref is passed through to @fastify/swagger.
    401: {
      description: 'Unauthorized — missing/invalid Bearer; the socket is closed with code 1008.',
      $ref: '#/components/schemas/ErrorEnvelope',
    },
  },
};

// Stable-ish pod identity for the ws:user routing hint (best-effort; the hint just
// records "a pod holds this user's socket", it is not load-bearing for delivery).
const POD_ID = process.env.HOSTNAME || process.env.POD_NAME || `pod-${process.pid}`;

// ── Process-wide local socket registry (for the single Redis cross-pod subscriber).
// userId → set of locally-held sockets. Each socket registers itself on connect and
// removes itself on close. The ONE Redis subscriber (started lazily, once per process)
// dispatches an incoming broadcast to exactly the matching local sockets.
type Sink = (event: any) => void;
const localSinks = new Map<string, Set<Sink>>();
let redisSubStarted = false;

async function ensureRedisDispatcher(): Promise<void> {
  if (redisSubStarted) return;
  redisSubStarted = true;
  try {
    await subscribeWsEvents((msg: WsBroadcast) => {
      const set = localSinks.get(msg.userId);
      if (!set || set.size === 0) return;
      for (const sink of set) {
        try { sink(msg.payload); } catch { /* one bad sink never blocks the rest */ }
      }
    });
    logger.info('notification.ws', 'cross-pod redis WS dispatcher started');
  } catch (e: any) {
    // Redis cross-pod fan-out degraded; per-socket NATS still works locally.
    redisSubStarted = false;
    logger.warn('notification.ws', `redis WS dispatcher not started (degraded): ${String(e?.message).slice(0, 80)}`);
  }
}

function addLocalSink(userId: string, sink: Sink): void {
  let set = localSinks.get(userId);
  if (!set) { set = new Set(); localSinks.set(userId, set); }
  set.add(sink);
}
function removeLocalSink(userId: string, sink: Sink): void {
  const set = localSinks.get(userId);
  if (!set) return;
  set.delete(sink);
  if (set.size === 0) localSinks.delete(userId);
}

// Derive a stable de-dupe id for an inbox event so the NATS copy and the Redis copy
// of the same notification are sent to the client once. Falls back to a JSON hash so
// an event without an id is still de-duped within the recent window.
function eventId(ev: any): string {
  if (ev && typeof ev === 'object') {
    if (ev._id != null) return `id:${String(ev._id)}`;
    if (ev.id != null) return `id:${String(ev.id)}`;
    if (ev.userId != null && ev.createdAt != null) return `uc:${ev.userId}:${String(ev.createdAt)}`;
  }
  try { return `h:${JSON.stringify(ev)}`; } catch { return `t:${Date.now()}`; }
}

export default async function (app: FastifyInstance, _opts: FastifyPluginOptions): Promise<void> {
  // Resolve the owner from the Bearer (Authorization header) or ?token= (for browsers
  // that cannot set a header on a WS upgrade). Used by BOTH the pre-upgrade auth hook
  // and the socket handler.
  const resolveUser = (req: FastifyRequest): string | null => {
    const headerAuth = req.headers['authorization'];
    const q = (req.query || {}) as Record<string, any>;
    const queryTok = typeof q.token === 'string' && q.token ? `Bearer ${q.token}` : undefined;
    const claims = verifyToken(headerAuth) || verifyToken(queryTok);
    return claims ? getUserId(claims) : null;
  };

  app.get('/ws/inbox', {
    websocket: true,
    schema: wsInboxSchema,
    // AUTH-ON-UPGRADE: refuse an unauthenticated upgrade with a REAL HTTP 401 BEFORE the
    // protocol switch (no 101). preValidation runs in the Fastify lifecycle during the
    // upgrade; sending a reply here aborts the handshake (the socket handler never runs).
    preValidation: async (req: FastifyRequest, reply: FastifyReply) => {
      const userId = resolveUser(req);
      if (!userId) {
        reply.code(401).send(buildEnvelope('unauthorized', 'a valid Bearer token is required', req.id));
        return reply;
      }
      (req as any).wsUserId = userId;
    },
  }, (socket: any, req: FastifyRequest) => {
    // Name the WS-upgrade transaction so it is a bounded route, not "undefined undefined".
    { const tx: any = apm.currentTransaction; if (tx) tx.name = 'GET /api/v1/notification/ws/inbox'; }
    // Defence in depth: preValidation already refused unauthenticated upgrades; this
    // re-check closes the socket (1008) if it is ever reached without an owner.
    const userId = (req as any).wsUserId || resolveUser(req);
    if (!userId) {
      try { socket.close(CLOSE_POLICY, 'unauthorized'); } catch { /* already closing */ }
      return;
    }

    let closed = false;
    let natsUnsub: (() => void) | null = null;
    // Per-socket de-dupe of recently-sent event ids (bounded — insertion-ordered Set).
    const seen = new Set<string>();
    const SEEN_MAX = 256;

    const safeSend = (obj: any): void => {
      if (closed || socket.readyState !== WS_OPEN) return;
      try { socket.send(JSON.stringify(obj)); } catch { /* peer gone; close handler cleans up */ }
    };

    // Forward an inbox event to this socket exactly once (NATS + Redis may both deliver).
    const forward = (ev: any): void => {
      const eid = eventId(ev);
      if (seen.has(eid)) return;
      seen.add(eid);
      if (seen.size > SEEN_MAX) { const first = seen.values().next().value; if (first !== undefined) seen.delete(first); }
      safeSend({ type: 'inbox', notification: ev });
    };

    // ── Register presence + both fan-out paths. Each step is independently guarded so
    // a single dependency outage never crashes the socket (degraded = no live push).
    wsConnInc();
    // Redis routing hint + the local registry sink (fed by the process-wide subscriber).
    void setWsUserPod(userId, POD_ID).catch(() => { /* degrade */ });
    addLocalSink(userId, forward);
    void ensureRedisDispatcher();
    // Per-user NATS subject (subjects are per-user, so this subscription is per socket).
    try { natsUnsub = subscribeInbox(userId, forward); } catch { natsUnsub = null; }

    // Single idempotent teardown (close / error / process-level failure).
    const cleanup = (): void => {
      if (closed) return;
      closed = true;
      try { natsUnsub?.(); } catch { /* ignore */ }
      removeLocalSink(userId, forward);
      wsConnDec();
      // NOTE: we do NOT delete ws:user:<id> here — another socket for the same user may
      // still be held by this pod, and the key carries its own session TTL. Leaving it is
      // safe (it is only a best-effort routing hint, never a delivery gate).
    };

    socket.on('close', cleanup);
    socket.on('error', (e: any) => {
      logger.warn('notification.ws', `socket error: ${String(e?.message).slice(0, 80)}`);
      cleanup();
    });
    // Inbound frames are not part of the contract (push-only stream); ignore the body,
    // never echo it (no PII / no client-controlled fan-out). Reply with a lightweight ack.
    socket.on('message', () => { safeSend({ type: 'ack' }); });

    // ── Hello/ack frame on connect (no PII — just identity + the live timestamp).
    safeSend({ type: 'hello', service: '14-notification', userId, ts: new Date().toISOString() });
  });
}
