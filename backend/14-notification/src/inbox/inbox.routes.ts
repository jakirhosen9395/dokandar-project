// Business REST (Fastify plugin, mounted at prefix /api/v1/notification by server.ts).
// All routes are Bearer-authed and owner-scoped: a plugin-level preHandler verifies the
// RS256 token and pins req.userId; Fastify encapsulation scopes this auth to THIS plugin
// only (the ops endpoints stay public). Routes are declared RELATIVE to the prefix.
//
// Pretty 2-space JSON, the error envelope, and request_id are all provided by server.ts
// (setReplySerializer/setSerializerCompiler, setErrorHandler honouring AppError, and the
// req.id honour-or-mint). Handlers RETURN plain objects and THROW AppError — they never
// pre-stringify a payload nor hand-build an envelope.
//
// PRIVACY: notification bodies (title_*/body_*) must NEVER be logged. These handlers do
// not log at all.
import { FastifyInstance, FastifyPluginOptions, FastifyRequest } from 'fastify';
import { ObjectId } from 'mongodb';

import { AppError } from '../common/errors';
import { verifyToken, getUserId } from '../auth/jwt';
import { notifications, preferences } from '../db/mongo';

// ── OpenAPI schema catalog (architecture.md §6) ─────────────────────────────────────────
// Declaring `response` schemas documents each route in @fastify/swagger. server.ts
// overrode the serializer compiler with a plain pretty-stringify, so these schemas do NOT
// field-filter the payload (no fast-json-stringify) — they are documentation only.

const NotificationSchema = {
  type: 'object',
  properties: {
    id: { type: 'string', description: 'opaque inbox document id' },
    userId: { type: 'string' },
    kind: { type: 'string', description: 'welcome | order_placed | payment_settled | kyc_approved | cashback | …' },
    category: { type: 'string', enum: ['transactional', 'promotional'] },
    title_bn: { type: 'string' },
    title_en: { type: 'string' },
    body_bn: { type: 'string' },
    body_en: { type: 'string' },
    deepLink: { type: 'string' },
    read: { type: 'boolean' },
    createdAt: { type: 'string', format: 'date-time' },
  },
};

const PreferencesSchema = {
  type: 'object',
  properties: {
    userId: { type: 'string' },
    channels: {
      type: 'object',
      properties: {
        sms: { type: 'boolean' },
        push: { type: 'boolean' },
        email: { type: 'boolean' },
        whatsapp: { type: 'boolean' },
      },
    },
  },
};

// The shared ErrorEnvelope component lives in server.ts (openapi.components.schemas).
// Response schemas reference it by $ref — safe here because server.ts overrides the
// serializer compiler with a plain pretty-stringify, so Fastify does NOT compile these
// response schemas with fast-json-stringify (no $ref resolution at registration time);
// the $ref is passed through verbatim to @fastify/swagger for the spec.
const ErrorEnvelopeSchema = { $ref: '#/components/schemas/ErrorEnvelope' };

const SECURITY = [{ bearerJwt: [] }];
const OID_24 = '^[a-fA-F0-9]{24}$';
const ALL_TRUE = { sms: true, push: true, email: true, whatsapp: true };

// Map a Mongo inbox doc → the API shape (ObjectId _id → opaque string `id`).
function toApi(d: any) {
  const { _id, ...rest } = d;
  return { id: String(_id), ...rest };
}

export default async function (app: FastifyInstance, _opts: FastifyPluginOptions): Promise<void> {
  // Plugin-scoped auth: verify the Bearer, pin the owner. 401 (not 403) on any failure —
  // no/blank/forged/expired token, or a token with no subject.
  app.addHook('preHandler', async (req: FastifyRequest) => {
    const claims = verifyToken(req.headers.authorization);
    const userId = claims ? getUserId(claims) : null;
    if (!userId) throw new AppError(401, 'unauthorized', 'a valid Bearer token is required');
    (req as any).userId = userId;
  });

  // GET /inbox?page=&size= — latest-N inbox for the user (createdAt desc, paged).
  app.get('/inbox', {
    schema: {
      tags: ['inbox'],
      operationId: 'listInbox',
      summary: 'Latest-N inbox for the authenticated user (paged)',
      description: 'Returns the authenticated user\'s notifications newest-first, paged. `page` is 1-based (default 1); `size` defaults to 20 and is capped at 100. Out-of-range or non-numeric values degrade to the defaults rather than erroring (no 422 on this route).',
      security: SECURITY,
      // No min/max/integer constraints here: §6 documents this route as 200·401 ONLY.
      // A strict schema would add an undocumented 422 surface (?size=abc, ?page=0,
      // ?size=500). The handler below parses + clamps defensively instead, so garbage
      // query params degrade to the defaults rather than rejecting the request.
      querystring: {
        type: 'object',
        properties: {
          page: { type: 'string', description: '1-based page (default 1)', example: '1' },
          size: { type: 'string', description: 'page size, capped at 100 (default 20)', example: '20' },
        },
      },
      response: {
        200: {
          description: 'A page of the user\'s notifications (newest first).',
          type: 'object',
          properties: {
            items: { type: 'array', items: NotificationSchema },
            page: { type: 'integer' },
            size: { type: 'integer' },
            total: { type: 'integer' },
          },
        },
        401: ErrorEnvelopeSchema,
        500: ErrorEnvelopeSchema,
      },
    },
  }, async (req: FastifyRequest) => {
    const userId = (req as any).userId as string;
    const q = req.query as { page?: string; size?: string };
    const pageRaw = parseInt(String(q.page ?? ''), 10);
    const sizeRaw = parseInt(String(q.size ?? ''), 10);
    const page = Number.isFinite(pageRaw) && pageRaw > 0 ? pageRaw : 1;
    const size = Number.isFinite(sizeRaw) && sizeRaw > 0 ? Math.min(sizeRaw, 100) : 20;
    const coll = notifications();
    const filter = { userId };
    const [docs, total] = await Promise.all([
      coll.find(filter).sort({ createdAt: -1 }).skip((page - 1) * size).limit(size).toArray(),
      coll.countDocuments(filter),
    ]);
    return { items: docs.map(toApi), page, size, total };
  });

  // POST /inbox/:id/read — mark one notification read (owner-scoped). 404 if not the user's.
  app.post('/inbox/:id/read', {
    schema: {
      tags: ['inbox'],
      operationId: 'markNotificationRead',
      summary: 'Mark a single notification read (owner-scoped)',
      description: 'Marks one of the authenticated user\'s notifications read. `id` must be a 24-hex MongoDB ObjectId; a malformed id is rejected as 422. A 404 is returned if the notification does not exist or is not owned by the caller (the two are not distinguished, to avoid leaking existence).',
      security: SECURITY,
      params: {
        type: 'object',
        // The 24-hex pattern keeps a malformed id from reaching new ObjectId() (which
        // would throw BSONError → 500); a bad id becomes a 422 via the validation path.
        properties: { id: { type: 'string', pattern: OID_24, description: '24-hex notification id', example: '5f9b1c2d3e4a5b6c7d8e9f01' } },
        required: ['id'],
      },
      response: {
        200: {
          description: 'The notification is now read.',
          type: 'object',
          properties: { id: { type: 'string' }, read: { type: 'boolean' } },
        },
        401: ErrorEnvelopeSchema,
        404: ErrorEnvelopeSchema,
        422: ErrorEnvelopeSchema,
        500: ErrorEnvelopeSchema,
      },
    },
  }, async (req: FastifyRequest) => {
    const userId = (req as any).userId as string;
    const { id } = req.params as { id: string };
    const res = await notifications().updateOne({ _id: new ObjectId(id), userId }, { $set: { read: true } });
    // matchedCount 0 → either non-existent or not the caller's; do not leak which.
    if (res.matchedCount === 0) throw new AppError(404, 'not_found', 'notification not found');
    return { id, read: true };
  });

  // POST /inbox/read-all — mark all of the user's notifications read.
  app.post('/inbox/read-all', {
    schema: {
      tags: ['inbox'],
      operationId: 'markAllNotificationsRead',
      summary: 'Mark all of the user\'s notifications read',
      description: 'Marks every unread notification for the authenticated user as read. `updated` is the number of rows changed (0 if none were unread). Idempotent.',
      security: SECURITY,
      response: {
        200: {
          description: 'Count of notifications transitioned to read.',
          type: 'object',
          properties: { updated: { type: 'integer', description: 'rows changed', example: 3 } },
        },
        401: ErrorEnvelopeSchema,
        500: ErrorEnvelopeSchema,
      },
    },
  }, async (req: FastifyRequest) => {
    const userId = (req as any).userId as string;
    const res = await notifications().updateMany({ userId, read: false }, { $set: { read: true } });
    return { updated: res.modifiedCount };
  });

  // GET /preferences — the user's channel opt-ins (default all-true if none yet).
  app.get('/preferences', {
    schema: {
      tags: ['preferences'],
      operationId: 'getPreferences',
      summary: 'The authenticated user\'s channel opt-ins',
      description: 'Returns the authenticated user\'s per-channel notification opt-ins. If the user has never set preferences, all four channels (sms/push/email/whatsapp) default to true.',
      security: SECURITY,
      response: {
        200: { description: 'The user\'s channel opt-ins.', ...PreferencesSchema },
        401: ErrorEnvelopeSchema,
        500: ErrorEnvelopeSchema,
      },
    },
  }, async (req: FastifyRequest) => {
    const userId = (req as any).userId as string;
    const doc = await preferences().findOne({ userId });
    return { userId, channels: doc?.channels ?? { ...ALL_TRUE } };
  });

  // PUT /preferences — upsert channel opt-ins. Bad body → 422 (server.ts maps validation).
  app.put('/preferences', {
    schema: {
      tags: ['preferences'],
      operationId: 'updatePreferences',
      summary: 'Update the authenticated user\'s channel opt-ins',
      description: 'Upserts the authenticated user\'s per-channel opt-ins. The `channels` object MUST carry all four booleans (sms/push/email/whatsapp); a partial or extra-keyed body is rejected as 422.',
      security: SECURITY,
      body: {
        type: 'object',
        // additionalProperties:false + required makes server.ts emit 422 on a bad body.
        example: { channels: { sms: true, push: true, email: false, whatsapp: true } },
        properties: {
          channels: {
            type: 'object',
            description: 'All four channel booleans are required.',
            properties: {
              sms: { type: 'boolean', description: 'SMS opt-in', example: true },
              push: { type: 'boolean', description: 'push opt-in', example: true },
              email: { type: 'boolean', description: 'email opt-in', example: false },
              whatsapp: { type: 'boolean', description: 'WhatsApp opt-in', example: true },
            },
            required: ['sms', 'push', 'email', 'whatsapp'],
            additionalProperties: false,
          },
        },
        required: ['channels'],
        additionalProperties: false,
      },
      response: {
        200: { description: 'The updated channel opt-ins.', ...PreferencesSchema },
        401: ErrorEnvelopeSchema,
        422: ErrorEnvelopeSchema,
        500: ErrorEnvelopeSchema,
      },
    },
  }, async (req: FastifyRequest) => {
    const userId = (req as any).userId as string;
    const { channels } = req.body as { channels: { sms: boolean; push: boolean; email: boolean; whatsapp: boolean } };
    await preferences().updateOne({ userId }, { $set: { userId, channels } }, { upsert: true });
    return { userId, channels };
  });
}
