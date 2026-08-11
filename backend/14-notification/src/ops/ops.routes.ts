// The five operational endpoints (Fastify plugin, no prefix): /ready /health /data
// /metrics. (/docs + /openapi.json are owned by server.ts via @fastify/swagger-ui.)
//
// CONTRACT CORRECTION vs 06-cart (architecture.md §8.1, §16-b): /ready and /health are
// gated on MongoDB ONLY. 06-cart computes `ok = m.ok && r.ok` in both — that is WRONG
// here. The inbox store (MongoDB) is the single dependency a request cannot be served
// without; redis/kafka/rabbitmq/nats/mongo_logs/apm are degradable/diagnostic and must
// NEVER flip the readiness or health status.
import { FastifyInstance, FastifyPluginOptions, FastifyReply, FastifyRequest } from 'fastify';
import * as fs from 'fs';
import * as net from 'net';

import { config } from '../config';
import { identity } from '../common/identity';
import { buildEnvelope } from '../common/errors';
import { ping as mongoPing } from '../db/mongo';
import { ping as redisPing } from '../db/redis';
import { mongoHealthy } from '../observability/logger';
import { render } from '../observability/metrics';

// TCP connect probe (diagnostic only — never a gate). Resolves false on error/timeout.
function tcp(host: string, port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const s = net.connect({ host, port, timeout: 1500 });
    s.on('connect', () => { s.destroy(); resolve(true); });
    s.on('error', () => resolve(false));
    s.on('timeout', () => { s.destroy(); resolve(false); });
  });
}

type Check = { ok: boolean; detail: string; latency_ms?: number };

// MongoDB liveness — the ONLY thing that gates /ready and drives /health status.
async function checkMongo(): Promise<Check> {
  const t = Date.now();
  try { await mongoPing(); return { ok: true, latency_ms: Date.now() - t, detail: 'ok' }; }
  catch (e: any) { return { ok: false, latency_ms: Date.now() - t, detail: `err:${String(e?.message).slice(0, 40)}` }; }
}

// Redis liveness (diagnostic only).
async function checkRedis(): Promise<Check> {
  const t = Date.now();
  try { await redisPing(); return { ok: true, latency_ms: Date.now() - t, detail: 'ok' }; }
  catch (e: any) { return { ok: false, latency_ms: Date.now() - t, detail: `err:${String(e?.message).slice(0, 40)}` }; }
}

// host:port probe from a bare "host:port" string (kafka bootstrap; first broker only).
async function probeHostPort(spec: string, defaultPort: number): Promise<Check> {
  if (!spec) return { ok: false, detail: 'not-configured' };
  const first = spec.split(',')[0].trim();
  const [h, p] = first.split(':');
  const ok = await tcp(h, parseInt(p, 10) || defaultPort);
  return { ok, detail: ok ? 'tcp-ok' : 'unreachable' };
}

// host:port probe from a URL string (nats://…, amqp://…).
async function probeUrl(url: string, defaultPort: number): Promise<Check> {
  if (!url) return { ok: false, detail: 'not-configured' };
  try {
    const u = new URL(url);
    const ok = await tcp(u.hostname, parseInt(u.port, 10) || defaultPort);
    return { ok, detail: ok ? 'tcp-ok' : 'unreachable' };
  } catch { return { ok: false, detail: 'bad-url' }; }
}

export default async function (app: FastifyInstance, _opts: FastifyPluginOptions): Promise<void> {
  // GET /ready — 200 iff MongoDB reachable (MONGO-ONLY gate). 503 otherwise.
  app.get('/ready', { schema: { tags: ['ops'], operationId: 'getReady', summary: 'Readiness — 200 iff MongoDB reachable (MongoDB-only gate)', description: 'LB/readiness gate. 200 only when MongoDB (the inbox system-of-record) is reachable; 503 otherwise. Redis/Kafka/RabbitMQ/NATS are degradable and never gate readiness. No auth.' } }, async (_req: FastifyRequest, reply: FastifyReply) => {
    const m = await checkMongo();
    reply.code(m.ok ? 200 : 503);
    return {
      status: m.ok ? 'ready' : 'not_ready',
      identity: identity(),
      dependencies: [{ name: 'mongodb', reachable: m.ok, latency_ms: m.latency_ms, detail: m.detail }],
    };
  });

  // GET /health — full diagnostics. Top-level status driven by MongoDB ONLY; every
  // other check is reported but NEVER flips the status.
  app.get('/health', { schema: { tags: ['ops'], operationId: 'getHealth', summary: 'Full diagnostics (status driven by MongoDB only)', description: 'Full dependency diagnostics over MongoDB, Redis, Kafka, RabbitMQ, NATS, the Mongo log sink and APM, plus an observability block. Top-level status is driven by MongoDB only; every other check is reported but never flips the status. No auth.' } }, async (_req: FastifyRequest, reply: FastifyReply) => {
    const [m, r, kafka, rabbitmq, nats] = await Promise.all([
      checkMongo(),
      checkRedis(),
      probeHostPort(config.kafkaBootstrap, 9092),
      probeUrl(config.rabbitmqUrl, 5672),
      probeUrl(config.natsUrl, 4222),
    ]);
    const apmOk = !!config.apmServerUrl;
    const logsOk = mongoHealthy();
    const healthy = m.ok; // MONGO-ONLY
    reply.code(healthy ? 200 : 503);
    return {
      status: healthy ? 'healthy' : 'unhealthy',
      identity: identity(),
      checks: {
        mongodb: m,
        redis: r,
        kafka,
        rabbitmq,
        nats,
        mongo_logs: { ok: logsOk, detail: logsOk ? 'ping-ok' : 'unreachable' },
        apm: { ok: apmOk, detail: apmOk ? 'configured' : 'disabled' },
      },
      observability: {
        apm_service_name: config.apmServiceName,
        logs_sink_es: `${config.esUrl}/logs-app-${config.serviceName}-*`,
        logs_sink_mongo: `${config.mongoLogDb}.${config.serviceName}`,
      },
    };
  });

  // GET /data — identity-prefixed read-only TENANT snapshot.
  app.get('/data', { schema: { tags: ['ops'], operationId: 'getData', summary: 'TENANT data snapshot (identity-prefixed)', description: 'Returns the identity block prepended to the read-only data/<tenant>/result.json snapshot (not live DB introspection). 404 no_snapshot if the file is absent; 500 snapshot_parse_failed if it is not a JSON object. No auth.' } }, async (req: FastifyRequest, reply: FastifyReply) => {
    for (const p of [`data/${config.tenant}/result.json`, `/app/data/${config.tenant}/result.json`]) {
      let raw: string;
      try { raw = fs.readFileSync(p, 'utf8'); } catch { continue; }
      try {
        const snap = JSON.parse(raw);
        if (snap && typeof snap === 'object' && !Array.isArray(snap)) {
          reply.code(200);
          return { identity: identity(), ...snap };
        }
        reply.code(500);
        return buildEnvelope('snapshot_parse_failed', 'snapshot root must be an object', req.id);
      } catch {
        reply.code(500);
        return buildEnvelope('snapshot_parse_failed', 'snapshot is not valid JSON', req.id);
      }
    }
    reply.code(404);
    return buildEnvelope('no_snapshot', `data/${config.tenant}/result.json not present (run data/${config.tenant}/collect.sh)`, req.id);
  });

  // GET /metrics — Prometheus text (the one non-pretty-JSON endpoint). Returning a
  // string bypasses the pretty serializer automatically; hidden from swagger.
  app.get('/metrics', { schema: { hide: true } }, async (_req: FastifyRequest, reply: FastifyReply) => {
    reply.header('content-type', 'text/plain; version=0.0.4; charset=utf-8');
    return render();
  });
}
