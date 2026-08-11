// Three-sink structured logging mirroring 01-auth/06-cart: stdout (JSON w/ elasticapm_*),
// MongoDB forensic sink (collection = serviceName), Elasticsearch data stream
// logs-app-14-notification-* on the APM-stack ES (:9200). Plus a plain HTTP
// access-log line. Trace correlation via the Elastic APM Node agent.
//
// CALLER CONTRACT: OTP codes and notification bodies (title_*/body_*) MUST NEVER be
// passed in `extra` — redaction is the caller's responsibility; this sink does not
// inspect or strip payloads beyond the Mongo `_id` removed before the ES _bulk.
import apm from '../apm';
import { config } from '../config';
import { MongoClient } from 'mongodb';
import axios from 'axios';

type Json = Record<string, any>;
const mongoQueue: Json[] = [];
const esQueue: Json[] = [];
let mongoColl: any = null;
let mongoUp = false;

function apmFields(): Json {
  const ids: any = (apm as any).currentTraceIds || {};
  const traceId = ids['trace.id'];
  const txId = ids['transaction.id'];
  const spanId = ids['span.id'] ?? null;
  const out: Json = {
    elasticapm_service_name: config.apmServiceName,
    elasticapm_service_environment: config.appEnv,
  };
  if (traceId) out.elasticapm_trace_id = traceId;
  if (txId) out.elasticapm_transaction_id = txId;
  out.elasticapm_labels = {
    'transaction.id': txId ?? null, 'trace.id': traceId ?? null, 'span.id': spanId,
    'service.name': config.apmServiceName, 'service.environment': config.appEnv,
  };
  return out;
}

function asctime(d: Date): string {
  const p = (n: number, w = 2) => String(n).padStart(w, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())},${p(d.getMilliseconds(), 3)}`;
}

export function log(level: string, name: string, message: string, extra: Json = {}): void {
  const now = new Date();
  const af = apmFields();
  const stdoutRec: Json = { asctime: asctime(now), name, levelname: level, message, ...af, ...extra };
  process.stdout.write(JSON.stringify(stdoutRec) + '\n');
  // ECS doc for the Mongo + ES sinks (with a real ts_date BSON-Date for any TTL)
  const doc: Json = {
    '@timestamp': now.toISOString(),
    ts_date: now,
    log: { level: level.toLowerCase(), logger: name },
    message,
    service: { name: config.serviceName, version: config.codeVersion, environment: config.appEnv },
    host: { name: process.env.HOSTNAME || '' },
    labels: { tenant: config.tenant, env_version: config.envVersion },
    ...af, ...extra,
  };
  if (af.elasticapm_trace_id) { doc.trace = { id: af.elasticapm_trace_id }; doc.transaction = { id: af.elasticapm_transaction_id }; }
  if (config.mongoLogUri) { mongoQueue.push(doc); if (mongoQueue.length > 5000) mongoQueue.shift(); }
  if (config.esUrl) { esQueue.push(doc); if (esQueue.length > 5000) esQueue.shift(); }
}
export const logger = {
  info: (n: string, m: string, e?: Json) => log('INFO', n, m, e),
  warn: (n: string, m: string, e?: Json) => log('WARNING', n, m, e),
  error: (n: string, m: string, e?: Json) => log('ERROR', n, m, e),
};
// plain access log → stdout only (the structured record is the APM transaction)
export function accessLog(ip: string, method: string, path: string, status: number, reason: string): void {
  const d = new Date();
  const p = (n: number, w = 2) => String(n).padStart(w, '0');
  const ts = `${p(d.getDate())}-${p(d.getMonth() + 1)}-${d.getFullYear()} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
  process.stdout.write(`${ts}    ${ip} - "${method} ${path} HTTP/1.1" ${status} ${reason}\n`);
}

export function mongoHealthy(): boolean { return mongoUp; }

export function startSinks(): void {
  if (config.mongoLogUri) {
    MongoClient.connect(config.mongoLogUri, { serverSelectionTimeoutMS: 4000 } as any).then((c) => {
      mongoColl = c.db(config.mongoLogDb).collection(config.serviceName); mongoUp = true;
    }).catch((e) => process.stderr.write(`mongo log sink connect failed: ${e}\n`));
    setInterval(async () => {
      if (!mongoColl || mongoQueue.length === 0) return;
      const batch = mongoQueue.splice(0, 500);
      try { await mongoColl.insertMany(batch, { ordered: false }); mongoUp = true; } catch { mongoUp = false; }
    }, 2000);
  }
  if (config.esUrl) {
    const ds = `logs-app-${config.serviceName}-default`;
    const auth = config.esUser ? { username: config.esUser, password: config.esPassword } : undefined;
    setInterval(async () => {
      if (esQueue.length === 0) return;
      const batch = esQueue.splice(0, 500);
      let body = ''; for (const d of batch) { const { _id, ...clean } = d as any; body += '{"create":{}}\n' + JSON.stringify(clean) + '\n'; }
      try {
        const resp = await axios.post(`${config.esUrl.replace(/\/$/, '')}/${ds}/_bulk`, body, { headers: { 'content-type': 'application/x-ndjson' }, auth, timeout: 5000, transformRequest: [(d: any) => d] });
        if (resp.data && resp.data.errors) process.stderr.write('ES sink bulk item error: ' + JSON.stringify(resp.data.items && resp.data.items[0]).slice(0, 300) + '\n');
      } catch (e: any) { process.stderr.write('ES sink POST failed: ' + (e.response ? e.response.status + ' ' + JSON.stringify(e.response.data).slice(0, 200) : e.message) + '\n'); }
    }, 2000);
  }
}
