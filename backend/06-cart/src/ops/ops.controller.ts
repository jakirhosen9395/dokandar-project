import { Controller, Get, Res } from '@nestjs/common';
import { ApiExcludeEndpoint, ApiOperation, ApiResponse, ApiTags } from '@nestjs/swagger';
import { ErrorEnvelopeModel } from '../cart/dto';
import { Response } from 'express';
import * as fs from 'fs';
import * as net from 'net';
import { config } from '../config';
import { MongoService } from '../mongo.service';
import { RedisService } from '../redis.service';
import { mongoHealthy } from '../observability/logger';
import { render } from '../observability/metrics';

const BOOT = Date.now();
function identity() { return { service_name: config.serviceName, code_version: config.codeVersion, env_version: config.envVersion, tenant: config.tenant, env: config.appEnv, uptime_seconds: Math.floor((Date.now() - BOOT) / 1000) }; }
function tcp(host: string, port: number): Promise<boolean> { return new Promise((r) => { const s = net.connect({ host, port, timeout: 1500 }); s.on('connect', () => { s.destroy(); r(true); }); s.on('error', () => r(false)); s.on('timeout', () => { s.destroy(); r(false); }); }); }

@ApiTags('ops')
@Controller()
export class OpsController {
  constructor(private readonly mongoSvc: MongoService, private readonly redis: RedisService) {}
  private pretty(res: Response, code: number, body: any) { res.status(code).type('application/json').send(JSON.stringify(body, null, 2) + '\n'); }
  private async mongo() { const t = Date.now(); try { await this.mongoSvc.ping(); return { ok: true, latency_ms: Date.now() - t, detail: 'ok' }; } catch (e: any) { return { ok: false, latency_ms: Date.now() - t, detail: `err:${String(e?.message).slice(0, 40)}` }; } }
  private async redisck() { const t = Date.now(); try { await this.redis.client.ping(); return { ok: true, latency_ms: Date.now() - t, detail: 'ok' }; } catch (e: any) { return { ok: false, latency_ms: Date.now() - t, detail: `err:${String(e?.message).slice(0, 40)}` }; } }
  private async probe(url: string) { if (!url) return { ok: false, detail: 'url-empty' }; try { const u = new URL(url); const ok = await tcp(u.hostname, parseInt(u.port) || 80); return { ok, detail: ok ? 'tcp-ok' : 'unreachable' }; } catch { return { ok: false, detail: 'bad-url' }; } }

  @Get('ready') @ApiOperation({ operationId: 'getReady', summary: 'Readiness probe — 200 iff MongoDB AND Redis reachable', description: 'LB/readiness gate. 200 only when MongoDB (cart store) and Redis DB5 (guest carts / idempotency, on the request path) are both reachable; otherwise 503.' }) @ApiResponse({ status: 200, description: 'ready' }) @ApiResponse({ status: 503, description: 'not_ready (a traffic-gating dependency is unreachable)' })
  async ready(@Res() res: Response) {
    const m = await this.mongo(), r = await this.redisck(); const ok = m.ok && r.ok;
    this.pretty(res, ok ? 200 : 503, { status: ok ? 'ready' : 'not_ready', identity: identity(), dependencies: [{ name: 'mongodb', reachable: m.ok, latency_ms: m.latency_ms, detail: m.detail }, { name: 'redis', reachable: r.ok, latency_ms: r.latency_ms, detail: r.detail }] });
  }
  @Get('health') @ApiOperation({ operationId: 'getHealth', summary: 'Liveness + every dependency health', description: 'Full diagnostics over all dependencies (Mongo, Redis, Kafka, mongo-logs, APM, catalog/coupon/risk peers) plus an observability block. Peer/broker checks are diagnostic-only and never flip overall status; status is unhealthy only if Mongo or Redis is down.' }) @ApiResponse({ status: 200, description: 'healthy' }) @ApiResponse({ status: 503, description: 'unhealthy (a core dependency is down)' })
  async health(@Res() res: Response) {
    const m = await this.mongo(), r = await this.redisck();
    const [kh, kp] = (config.kafkaBootstrap || ':9092').split(':'); const kok = await tcp(kh, parseInt(kp) || 9092);
    const apmOk = !!config.apmServerUrl;
    const cat = await this.probe(config.catalogHttpUrl), cou = await this.probe(config.couponHttpUrl), rk = await this.probe(config.riskHttpUrl);
    const healthy = m.ok && r.ok;
    this.pretty(res, healthy ? 200 : 503, {
      status: healthy ? 'healthy' : 'unhealthy', identity: identity(),
      checks: {
        mongodb: m, redis: r, kafka: { ok: kok, detail: kok ? 'metadata-ok' : 'unreachable' },
        mongo_logs: { ok: mongoHealthy(), detail: mongoHealthy() ? 'ping-ok' : 'unreachable' },
        apm: { ok: apmOk, detail: apmOk ? 'configured' : 'disabled' },
        catalog: cat, coupon: cou, risk: rk,
      },
      observability: { apm_service_name: config.apmServiceName, logs_sink_es: `${config.esUrl}/logs-app-${config.serviceName}-*`, logs_sink_mongo: `${config.mongoLogDb}.${config.serviceName}` },
    });
  }
  @Get('data') @ApiOperation({ operationId: 'getData', summary: 'Tenant data snapshot', description: 'Identity block prepended to the read-only data/<tenant>/result.json snapshot (not live DB introspection). 404 no_snapshot / 500 snapshot_parse_failed are contract responses.' }) @ApiResponse({ status: 200, description: 'identity + snapshot' }) @ApiResponse({ status: 404, description: 'no_snapshot', type: ErrorEnvelopeModel }) @ApiResponse({ status: 500, description: 'snapshot_parse_failed', type: ErrorEnvelopeModel })
  async data(@Res() res: Response) {
    for (const p of [`data/${config.tenant}/result.json`, `/app/data/${config.tenant}/result.json`]) {
      try { const snap = JSON.parse(fs.readFileSync(p, 'utf8')); if (snap && typeof snap === 'object' && !Array.isArray(snap)) { return this.pretty(res, 200, { identity: identity(), ...snap }); } return this.pretty(res, 500, { error: { code: 'snapshot_parse_failed', message: 'snapshot root must be an object' } }); } catch {}
    }
    this.pretty(res, 404, { error: { code: 'no_snapshot', message: `data/${config.tenant}/result.json not present (run data/${config.tenant}/collect.sh)` } });
  }
  @Get('metrics') @ApiExcludeEndpoint()
  async metrics(@Res() res: Response) { res.status(200).type('text/plain; version=0.0.4; charset=utf-8').send(await render()); }
}
