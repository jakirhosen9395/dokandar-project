import apm from './apm'; // MUST be the literal first import — the Elastic APM agent monkey-patches
                // http/mongodb/ioredis/kafkajs/amqplib BEFORE they are required anywhere else.
                // Do NOT import db/mongo or db/redis above this line.

import Fastify, { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { randomUUID } from 'crypto';

import { config } from './config';
import { accessLog, logger, startSinks } from './observability/logger';
import { observe } from './observability/metrics';
import { buildEnvelope, AppError } from './common/errors';

import { connectMongo, closeMongo } from './db/mongo';
import { connectRedis, closeRedis } from './db/redis';

// Route plugins (Fastify plugins, default export) + eventing starters. These are
// authored by the logic agents; the paths/exports are FIXED so the skeleton wires
// them with zero drift. The eventing starters are wrapped in try/catch at runtime
// (best-effort; they must never block listen) — a not-yet-present module would only
// fail tsc (the orchestrator compiles AFTER all agents land), never half-mount HTTP.
import opsRoutes from './ops/ops.routes';            // (app, opts) => Promise<void> — no prefix
import inboxRoutes from './inbox/inbox.routes';       // (app, opts) => Promise<void> — prefix /api/v1/notification
import wsRoutes from './realtime/ws';                 // (app, opts) => Promise<void> — prefix /api/v1/notification; uses @fastify/websocket
import { startConsumers } from './consumers/kafka.consumer';        // () => Promise<void>
import { startChannelWorkers } from './channels/rabbitmq.worker';   // () => Promise<void>
import { connectNats } from './realtime/nats';                      // () => Promise<void>

// Routes excluded from the access log AND the RED metric (architecture §11/§16-j).
const SILENT_ROUTES = new Set(['/ready', '/metrics', '/health']);
// NOTE on pretty-JSON exemptions (/metrics, /docs, /openapi.json): Fastify's
// reply serializer is NOT invoked for string/Buffer/stream payloads, so the
// metrics text and the swagger-ui assets bypass the pretty serializer automatically
// — no explicit skip-set is needed.

function buildApp(): FastifyInstance {
  // requestIdHeader + genReqId IS honour-or-mint: Fastify reads x-request-id if present,
  // else generates one. req.id is the canonical id for handlers / envelope / access log.
  const app = Fastify({
    logger: false,
    requestIdHeader: 'x-request-id',
    requestIdLogLabel: 'request_id',
    genReqId: () => randomUUID().replace(/-/g, ''),
    disableRequestLogging: true,
    bodyLimit: 1_048_576,
    // Route schemas carry the OpenAPI `example` annotation, which Ajv's strict
    // mode (Fastify 5 default) rejects as an unknown keyword — that aborted boot
    // with "strict mode: unknown keyword: example". strictSchema:false makes Ajv
    // ignore unknown annotation keywords (example) while keeping the rest of strict
    // mode; a plain object (vs an ajv plugin fn) also avoids widening Fastify's
    // inferred server type.
    ajv: {
      customOptions: { strictSchema: false },
    },
  });

  // PRETTY JSON (2-space). TWO serializers are required:
  //  - setReplySerializer covers schema-less replies (reply.send(obj)).
  //  - setSerializerCompiler covers routes that declare a response JSON schema
  //    (Fastify otherwise compiles those with fast-json-stringify → compact output).
  // JSON.stringify already emits literal UTF-8, so Bangla is not escaped.
  app.setReplySerializer((payload) => JSON.stringify(payload, null, 2));
  app.setSerializerCompiler(() => (data) => JSON.stringify(data, null, 2));

  // Echo the request id on every response (honour-or-mint already done by genReqId).
  app.addHook('onRequest', async (req: FastifyRequest, reply: FastifyReply) => {
    reply.header('x-request-id', req.id);
  });

  // RED metrics + access log on response. Use the TEMPLATED route (routeOptions.url,
  // e.g. /api/v1/notification/inbox/:id/read) — NEVER req.url — so path params never
  // explode metric cardinality (the closed-set-label rule). Exclude /ready,/metrics,/health.
  app.addHook('onResponse', async (req: FastifyRequest, reply: FastifyReply) => {
    const route = req.routeOptions?.url || req.url;
    if (SILENT_ROUTES.has(route)) return;
    const secs = reply.elapsedTime / 1000; // ms → s
    observe(req.method, route, reply.statusCode, secs);
    const ip = `${req.socket.remoteAddress}:${req.socket.remotePort}`;
    accessLog(ip, req.method, req.url, reply.statusCode, String(reply.statusCode));
  });

  // Error envelope { error: { code, message, request_id, details? } }.
  //  - Fastify validation (error.validation) → 422 (architecture §6 preferences PUT).
  //  - AppError → its statusCode/code/details.
  //  - any other 5xx → SCRUB the message (never leak driver/stack); log the raw cause
  //    to the forensic sink with the request_id.
  app.setErrorHandler((err: any, req: FastifyRequest, reply: FastifyReply) => {
    const rid = req.id;
    if (err?.validation) {
      const details = (err.validation || []).map((v: any) => ({ field: v.instancePath || v.params?.missingProperty || '', message: v.message }));
      reply.code(422).send(buildEnvelope('invalid_request', 'request validation failed', rid, details));
      return;
    }
    if (err instanceof AppError) {
      reply.code(err.statusCode).send(buildEnvelope(err.code, err.message, rid, err.details));
      return;
    }
    const status = typeof err?.statusCode === 'number' ? err.statusCode : 500;
    if (status >= 500) {
      logger.error('notification.error', 'unhandled error', { request_id: rid, err: String(err?.stack || err?.message || err).slice(0, 1000) });
      reply.code(status).send(buildEnvelope('internal_error', 'an internal error occurred', rid));
      return;
    }
    // client-side 4xx that wasn't an AppError (e.g. 400/404 from Fastify internals).
    reply.code(status).send(buildEnvelope(err?.code || 'bad_request', err?.message || 'bad request', rid));
  });

  // BARE 404 on unmapped paths: NO body, NO Content-Type, Content-Length: 0.
  // reply.send('') would re-attach a content-type — hijack the raw socket instead.
  app.setNotFoundHandler((req: FastifyRequest, reply: FastifyReply) => {
    // Bound APM cardinality: name unmatched 404s "<METHOD> unmatched" (Fastify otherwise reports
    // these as "undefined undefined" since no route matched).
    const tx: any = apm.currentTransaction; if (tx) tx.name = `${req.method} unmatched`;
    reply.hijack();
    reply.raw.writeHead(404, { 'Content-Length': '0' });
    reply.raw.end();
  });

  return app;
}

async function registerOpenApi(app: FastifyInstance): Promise<void> {
  // @fastify/swagger (the SPEC) is registered BEFORE the routes (ordering is load-bearing).
  const swagger = (await import('@fastify/swagger')).default;
  const description =
    `**service_name**: \`${config.serviceName}\` &nbsp;|&nbsp; **code_version**: \`${config.codeVersion}\` ` +
    `&nbsp;|&nbsp; **env_version**: \`${config.envVersion}\` &nbsp;|&nbsp; **tenant**: \`${config.tenant}\` ` +
    `&nbsp;|&nbsp; **env**: \`${config.appEnv}\`\n\n` +
    '**14-notification** — event-to-user fan-out: per-user MongoDB inbox, realtime WebSocket push ' +
    '(NATS + Redis pub/sub), and per-channel RabbitMQ dispatch (SMS/WhatsApp/push/email). Terminal ' +
    'Kafka consumer — emits nothing. Pretty-JSON (2-space, literal UTF-8 so Bangla is unescaped); ' +
    'errors use the platform envelope `{error:{code,message,request_id,details}}` with lowercase ' +
    'snake_case codes.\n\n' +
    '### How to test\n' +
    '1. Click **Authorize** and paste a Bearer **access token** from the auth service ' +
    '(`POST /api/v1/auth/login/request` → `/login/verify`). Every `/api/v1/notification/*` route is ' +
    'Bearer-authed and owner-scoped to the token subject; the `ops` endpoints (`/ready /health /data ' +
    '/metrics`) need no token.\n' +
    '2. `GET /inbox?page=&size=` returns the latest notifications for the token subject (newest first, ' +
    'page size capped at 100). `POST /inbox/{id}/read` and `/inbox/read-all` mark them read.\n' +
    '3. `GET /preferences` / `PUT /preferences` read and upsert the per-channel opt-ins ' +
    '(`sms`,`push`,`email`,`whatsapp` — all four are required on PUT).\n' +
    '4. `GET /ws/inbox` is a WebSocket upgrade (Authorization header or `?token=`); a missing/invalid ' +
    'token closes the socket with code 1008 (documented as 401).';
  await app.register(swagger as any, {
    openapi: {
      info: {
        title: 'DOKANDAR Notification Service',
        version: config.codeVersion,
        description,
        contact: { name: 'DOKANDAR Platform', url: 'https://dokandar.com.bd', email: 'api@dokandar.com.bd' },
        license: { name: 'Proprietary' },
      },
      servers: [
        { url: 'https://api.dokandar.com.bd', description: 'prod' },
        { url: 'http://localhost:10014', description: 'local' },
      ],
      components: {
        securitySchemes: {
          bearerJwt: { type: 'http', scheme: 'bearer', bearerFormat: 'JWT', description: 'RS256 access token minted by 01-auth' },
        },
        schemas: {
          // Single shared platform error envelope. Referenced by every documented 4xx/5xx
          // response via $ref. Shape matches src/common/errors.ts buildEnvelope().
          ErrorEnvelope: {
            type: 'object',
            description: 'Platform error envelope. `code` is a stable lowercase snake_case machine code; `request_id` echoes the honour-or-mint x-request-id.',
            required: ['error'],
            properties: {
              error: {
                type: 'object',
                required: ['code', 'message', 'request_id'],
                properties: {
                  code: { type: 'string', example: 'not_found' },
                  message: { type: 'string', example: 'notification not found' },
                  request_id: { type: 'string', example: 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6' },
                  details: { type: 'object', additionalProperties: true, description: 'optional structured context (e.g. validation field errors)' },
                },
              },
            },
          },
        },
      },
      tags: [
        { name: 'ops', description: 'Operational contract — readiness, health, data, metrics. No auth.' },
        { name: 'inbox', description: 'Per-user notification inbox: list and mark-read (owner-scoped).' },
        { name: 'preferences', description: 'Per-user channel opt-ins (sms/push/email/whatsapp).' },
        { name: 'realtime', description: 'Realtime inbox WebSocket stream (NATS + cross-pod Redis fan-out).' },
      ],
    },
  });
}

async function registerSwaggerUi(app: FastifyInstance): Promise<void> {
  // @fastify/swagger-ui (the UI) is registered AFTER the routes. UI at /docs.
  // NOTE: swagger-ui's own JSON lives at /docs/json; the contract requires the
  // document at /openapi.json, so we mount an explicit route that returns the
  // composed document (app.swagger() — decorated by @fastify/swagger above).
  const swaggerUi = (await import('@fastify/swagger-ui')).default;
  await app.register(swaggerUi as any, {
    routePrefix: '/docs',
    // Browser <title> MUST be exactly "14-notification API" (fleet doc standard).
    // @fastify/swagger-ui v5 renders the served HTML <title> from theme.title.
    theme: { title: '14-notification API' },
    uiConfig: { persistAuthorization: true, tryItOutEnabled: true },
  });
  app.get('/openapi.json', { schema: { hide: true } }, async (_req, reply) => {
    reply.header('content-type', 'application/json; charset=utf-8');
    return (app as any).swagger();
  });
}

async function bootstrap(): Promise<void> {
  // Sinks first so every subsequent boot line is captured.
  startSinks();

  // Fail-fast: SERVICE_NAME is required ALWAYS; JWT_PUBLIC_KEY_B64 is required under
  // stage/prod (a verify-only service with no public key would 401 every authed call).
  if (!config.serviceName) {
    process.stderr.write('FATAL: SERVICE_NAME is empty\n');
    process.exit(1);
  }
  if ((config.appEnv === 'stage' || config.appEnv === 'prod') && !config.jwtPublicKeyB64) {
    process.stderr.write(`FATAL: JWT_PUBLIC_KEY_B64 is empty under APP_ENV=${config.appEnv}\n`);
    process.exit(1);
  }

  logger.info('notification.boot', `starting ${config.serviceName} code_version=${config.codeVersion} port=${config.servicePort} tenant=${config.tenant} env=${config.appEnv}`);

  // Mongo is the /ready gate — connect + ensureDb (collections + the 90d TTL index)
  // BEFORE binding the listener. A failure here is fatal.
  try {
    await connectMongo();
  } catch (e: any) {
    process.stderr.write(`FATAL: mongo connect failed: ${String(e?.message || e)}\n`);
    process.exit(1);
  }

  // Redis is DEGRADABLE — best-effort, never fatal, never a gate.
  try { await connectRedis(); } catch (e: any) { logger.warn('notification.boot', `redis init deferred: ${String(e?.message)}`); }

  const app = buildApp();

  // Register order (LOAD-BEARING): swagger spec → websocket → route plugins → swagger-ui.
  // Route-plugin registration failures are NOT swallowed — a half-mounted service must
  // crash boot rather than report "listening".
  await registerOpenApi(app);

  const fastifyWebsocket = (await import('@fastify/websocket')).default;
  await app.register(fastifyWebsocket as any);

  await app.register(opsRoutes);                                           // ops: no prefix (/ready /health /data /metrics)
  await app.register(inboxRoutes, { prefix: '/api/v1/notification' });     // inbox + preferences
  await app.register(wsRoutes, { prefix: '/api/v1/notification' });        // /ws/inbox

  await registerSwaggerUi(app);

  // Eventing starters — best-effort, logged, NEVER block listen. Each in its own
  // try/catch so a single broker outage (or not-yet-wired module) can't stop the API.
  try { await connectNats(); } catch (e: any) { logger.warn('notification.boot', `nats not started: ${String(e?.message)}`); }
  try { await startConsumers(); } catch (e: any) { logger.warn('notification.boot', `kafka consumers not started: ${String(e?.message)}`); }
  try { await startChannelWorkers(); } catch (e: any) { logger.warn('notification.boot', `rabbitmq channel workers not started: ${String(e?.message)}`); }

  await app.listen({ port: config.servicePort, host: '0.0.0.0' });
  logger.info('notification.boot', `http server listening on :${config.servicePort}`);

  // Graceful shutdown.
  const shutdown = async (sig: string) => {
    logger.warn('notification.boot', `received ${sig}, draining`);
    try { await app.close(); } catch { /* ignore */ }
    try { await closeRedis(); } catch { /* ignore */ }
    try { await closeMongo(); } catch { /* ignore */ }
    process.exit(0);
  };
  process.on('SIGTERM', () => void shutdown('SIGTERM'));
  process.on('SIGINT', () => void shutdown('SIGINT'));
}

bootstrap().catch((e) => {
  process.stderr.write(`FATAL: bootstrap failed: ${String(e?.stack || e)}\n`);
  process.exit(1);
});
