"""
dkdscaffold.runtimes.node — Node/TypeScript runtime emitter. Emits a complete, strict-TypeScript
service skeleton (ESM, NodeNext) using node:http (stdlib, zero framework deps) realising the blueprint.
Consumes @dokandar/platform-sdk. No business logic.
"""
from __future__ import annotations
from ..blueprint import Service
from ..render import Writer
from .common import emit_common

SDK = "@dokandar/platform-sdk"


def emit(svc: Service, out_dir: str) -> list[str]:
    w = Writer(out_dir, "//")
    emit_common(w, svc)

    w.write("package.json", '''{
  "name": "%s",
  "version": "0.1.0",
  "description": "DOKANDAR %s service (generated; infrastructure only)",
  "type": "module",
  "private": true,
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "start": "node dist/src/index.js",
    "test": "tsc -p tsconfig.json && node --test dist/test/health.test.js"
  },
  "dependencies": { "%s": "1.0.0" },
  "devDependencies": { "typescript": "^5.7.0", "@types/node": "^24.0.0" }
}
''' % (svc.slug, svc.context, SDK))

    w.write("tsconfig.json", '''{
  "compilerOptions": {
    "target": "ES2022", "module": "NodeNext", "moduleResolution": "NodeNext",
    "strict": true, "outDir": "dist", "rootDir": ".", "esModuleInterop": true,
    "skipLibCheck": true, "forceConsistentCasingInFileNames": true, "declaration": false
  },
  "include": ["src/**/*.ts", "test/**/*.ts"]
}
''')

    w.write("src/config.ts", '''// 12-factor config from the environment; secrets via the platform secret manager.
export interface Config {
  serviceName: string; context: string; env: string;
  httpPort: number; metricsPort: number; logLevel: string;
  kafkaBrokers: string; rabbitUrl: string; dbDsn: string; otelEndpoint: string; jwtIssuer: string;
}

function env(k: string, def: string): string {
  const v = process.env[k];
  return v === undefined || v === "" ? def : v;
}

export function load(): Config {
  return {
    serviceName: env("DKD_SERVICE_NAME", "%s"),
    context: env("DKD_CONTEXT", "%s"),
    env: env("DKD_ENV", "local"),
    httpPort: Number(env("DKD_HTTP_PORT", "%d")),
    metricsPort: 9090,
    logLevel: env("DKD_LOG_LEVEL", "info"),
    kafkaBrokers: env("DKD_KAFKA_BROKERS", "localhost:9092"),
    rabbitUrl: env("DKD_RABBITMQ_URL", ""),
    dbDsn: env("DKD_DB_DSN", ""),
    otelEndpoint: env("DKD_OTEL_ENDPOINT", ""),
    jwtIssuer: env("DKD_JWT_ISSUER", ""),
  };
}

export function validate(c: Config): void { // startup validation — fail fast
  if (!c.serviceName || !c.context) throw new Error("service name and context are required");
  if (!Number.isInteger(c.httpPort) || c.httpPort <= 0) throw new Error(`invalid http port ${c.httpPort}`);
}
''' % (svc.slug, svc.context, svc.http_port))

    w.write("src/obs/logging.ts", '''// Structured JSON logging (stdout).
export type Fields = Record<string, unknown>;

export class Logger {
  info(msg: string, f: Fields = {}): void { this.emit("info", msg, f); }
  error(msg: string, f: Fields = {}): void { this.emit("error", msg, f); }
  private emit(level: string, msg: string, f: Fields): void {
    process.stdout.write(JSON.stringify({ ts: Date.now(), level, msg, ...f }) + "\\n");
  }
}
''')

    w.write("src/obs/metrics.ts", '''// Minimal, dependency-free Prometheus-text counter registry.
export class Metrics {
  private counters = new Map<string, number>();
  inc(name: string): void { this.counters.set(name, (this.counters.get(name) ?? 0) + 1); }
  expose(): string {
    let out = "";
    for (const [name, v] of this.counters) out += `${name} ${v}\\n`;
    return out;
  }
}
''')

    w.write("src/obs/tracing.ts", '''import { randomBytes } from "node:crypto";
// W3C traceparent propagation. The OpenTelemetry SDK is the export integration point.
export function newTraceParent(): string {
  return `00-${randomBytes(16).toString("hex")}-${randomBytes(8).toString("hex")}-01`;
}
export function newCorrelationId(): string { return randomBytes(16).toString("hex"); }
''')

    w.write("src/security/jwt.ts", '''// JWT authentication + authorization. Signature verification is delegated to an injectable
// Verifier (the platform JWKS integration point).
export interface Claims { sub?: string; kyc_tier?: string; roles?: string[]; cid?: string; }

export interface Verifier { verify(token: string): boolean; }
export class NoopVerifier implements Verifier { verify(): boolean { return true; } }

export class Jwt {
  constructor(public readonly issuer: string, private readonly verifier: Verifier = new NoopVerifier()) {}

  parse(authorization: string | undefined): Claims | null {
    if (!authorization || !authorization.startsWith("Bearer ")) return null;
    const token = authorization.slice("Bearer ".length);
    const parts = token.split(".");
    if (parts.length !== 3) return null;
    if (!this.verifier.verify(token)) return null;
    try {
      const payload = Buffer.from(parts[1], "base64url").toString("utf8");
      return JSON.parse(payload) as Claims;
    } catch { return null; }
  }
}

export function hasRole(c: Claims | null, role: string): boolean {
  return !!c && Array.isArray(c.roles) && c.roles.includes(role);
}
''')

    w.write("src/messaging/messaging.ts", '''// Kafka + RabbitMQ bootstrap abstractions. Concrete drivers (Redpanda/RabbitMQ) implement these at
// the integration point. No business events (R6: events are the Published Language).
export interface Publisher {
  publish(topic: string, key: string, payload: Uint8Array): Promise<void>;
  close(): Promise<void>;
}
export interface Consumer {
  subscribe(topics: string[], handle: (topic: string, key: string, payload: Uint8Array) => Promise<void>): Promise<void>;
  close(): Promise<void>;
}
export interface KafkaConfig { brokers: string; }
export interface RabbitConfig { url: string; }

export class NoopPublisher implements Publisher {
  async publish(): Promise<void> { /* wired to the broker at the integration point */ }
  async close(): Promise<void> { /* no-op */ }
}
''')

    w.write("src/persistence/persistence.ts", '''// DB abstraction + tx helper + repository base + migrations. The concrete driver (pg) is wired at
// the integration point. No business repositories.
export interface Tx { exec(sql: string, args?: unknown[]): Promise<void>; }
export interface Db {
  ping(): Promise<void>;
  withTx<T>(fn: (tx: Tx) => Promise<T>): Promise<T>;
  close(): Promise<void>;
}
export interface Migrator { apply(): Promise<void>; }

export abstract class RepositoryBase {
  constructor(protected readonly db: Db) {}
  protected inTx<T>(fn: (tx: Tx) => Promise<T>): Promise<T> { return this.db.withTx(fn); }
}
''')

    w.write("src/validation/validation.ts", '''// Boundary input validation (EF C7: reject, never coerce).
export function required(field: string, value: string | undefined): void {
  if (!value) throw new Error(`${field} is required`);
}
''')

    w.write("src/http/health.ts", '''import type { ServerResponse } from "node:http";
import { CONTRACT_VERSION, GENERATOR_VERSION } from "%s";

export function json(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}

export function health(res: ServerResponse): void {
  json(res, 200, { success: true, data: { status: "ok" } });
}
export function live(res: ServerResponse): void {
  json(res, 200, { success: true, data: { status: "alive" } });
}
export function ready(res: ServerResponse, isReady: boolean): void {
  if (!isReady) { json(res, 503, { success: false, data: { status: "not-ready" } }); return; }
  json(res, 200, { success: true, data: { status: "ready" } });
}
export function version(res: ServerResponse): void {
  json(res, 200, { success: true, data: { contractVersion: CONTRACT_VERSION, sdkGenerator: GENERATOR_VERSION } });
}
''' % SDK)

    w.write("src/http/server.ts", '''import http from "node:http";
import type { IncomingMessage, ServerResponse } from "node:http";
import { Logger } from "../obs/logging.js";
import { Metrics } from "../obs/metrics.js";
import { newCorrelationId, newTraceParent } from "../obs/tracing.js";
import { health, live, ready, version, json } from "./health.js";
import { handleDocs, isDocsPath, DOCS_CSP } from "@dokandar/platform-sdk";

function securityHeaders(res: ServerResponse, path: string): void {
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("Referrer-Policy", "no-referrer");
  // API Documentation Standard: relax CSP only for the Swagger UI paths; strict elsewhere.
  if (isDocsPath(path)) {
    res.setHeader("Content-Security-Policy", DOCS_CSP);
  } else {
    res.setHeader("X-Frame-Options", "DENY");
    res.setHeader("Content-Security-Policy", "default-src 'none'");
  }
}

export function createServers(
  port: number, metricsPort: number, log: Logger, metrics: Metrics, isReady: () => boolean, serviceName: string,
): { http: http.Server; metrics: http.Server } {
  const app = http.createServer((req: IncomingMessage, res: ServerResponse) => {
    const start = Date.now();
    const cid = (req.headers["x-correlation-id"] as string) || newCorrelationId();
    res.setHeader("X-Correlation-Id", cid);
    if (!req.headers["traceparent"]) req.headers["traceparent"] = newTraceParent();
    securityHeaders(res, req.url ?? "");
    metrics.inc("http_requests_total");
    try {
      // API Documentation Standard: Swagger UI /docs + OpenAPI JSON /swagger/v1/swagger.json (SDK helper).
      if (handleDocs(req, res, serviceName)) return;
      switch (req.url) {
        case "/health": health(res); break;
        case "/live": live(res); break;
        case "/ready": ready(res, isReady()); break;
        case "/version": version(res); break;
        default: json(res, 404, { success: false, error: { type: "about:blank", title: "not found", status: 404, code: "dokandar.%s.http.not_found" } });
      }
    } catch (e) {
      log.error("request failed", { err: String(e), path: req.url });
      json(res, 500, { success: false, error: { type: "about:blank", title: "internal error", status: 500, code: "dokandar.%s.internal.unhandled" } });
    } finally {
      log.info("request", { method: req.method, path: req.url, correlation_id: cid, elapsed_ms: Date.now() - start });
    }
  });

  const metricsSrv = http.createServer((_req, res) => {
    res.writeHead(200, { "Content-Type": "text/plain; version=0.0.4" });
    res.end(metrics.expose());
  });

  app.listen(port);
  metricsSrv.listen(metricsPort);
  return { http: app, metrics: metricsSrv };
}
''' % (svc.context, svc.context))

    w.write("src/app.ts", '''import { Logger } from "./obs/logging.js";
import { Metrics } from "./obs/metrics.js";
import { createServers } from "./http/server.js";
import { Jwt } from "./security/jwt.js";
import { NoopPublisher, type Publisher } from "./messaging/messaging.js";
import type { Config } from "./config.js";

// App is the dependency-injection container: it constructs and owns the service's adapters.
export class App {
  private servers?: { http: import("node:http").Server; metrics: import("node:http").Server };
  private publisher: Publisher = new NoopPublisher();
  private ready = false;
  readonly jwt: Jwt;

  constructor(private readonly cfg: Config, private readonly log: Logger) {
    this.jwt = new Jwt(cfg.jwtIssuer);
  }

  start(): void {
    const metrics = new Metrics();
    this.servers = createServers(this.cfg.httpPort, this.cfg.metricsPort, this.log, metrics, () => this.ready, this.cfg.serviceName);
    this.ready = true; // flip once dependencies connect
    this.log.info("started", { service: this.cfg.serviceName, port: this.cfg.httpPort });
  }

  async stop(): Promise<void> {
    this.ready = false;
    await this.publisher.close();
    await new Promise<void>((resolve) => this.servers?.http.close(() => resolve()));
    await new Promise<void>((resolve) => this.servers?.metrics.close(() => resolve()));
  }
}
''')

    w.write("src/index.ts", '''import { load, validate } from "./config.js";
import { Logger } from "./obs/logging.js";
import { App } from "./app.js";

const log = new Logger();
const cfg = load();
validate(cfg);                          // startup validation
const app = new App(cfg, log);
app.start();

async function shutdown(): Promise<void> { // graceful shutdown
  log.info("shutting down");
  await app.stop();
  process.exit(0);
}
process.on("SIGINT", () => void shutdown());
process.on("SIGTERM", () => void shutdown());
''')

    w.write("test/health.test.ts", '''import { test } from "node:test";
import assert from "node:assert/strict";
import type { IncomingMessage, ServerResponse } from "node:http";
import { Metrics } from "../src/obs/metrics.js";
import { Jwt, hasRole } from "../src/security/jwt.js";
import { handleDocs } from "@dokandar/platform-sdk";

// API Documentation Standard: Swagger UI /docs + OpenAPI JSON /swagger/v1/swagger.json + Bearer.
test("apidocs serves /docs and /swagger/v1/swagger.json with a Bearer scheme", () => {
  const cap = (url: string): { code: number; body: string } => {
    let body = "";
    const res = { statusCode: 0, setHeader() {}, end(b?: string) { body = b ?? ""; } } as unknown as ServerResponse;
    const handled = handleDocs({ url } as IncomingMessage, res, "test-svc");
    assert.equal(handled, true);
    return { code: (res as unknown as { statusCode: number }).statusCode, body };
  };
  assert.equal(cap("/docs").code, 200);
  const spec = cap("/swagger/v1/swagger.json");
  assert.equal(spec.code, 200);
  const doc = JSON.parse(spec.body);
  assert.equal(doc.info.version, "v1");
  assert.ok(doc.components.securitySchemes.Bearer);
});

test("metrics counter exposes prometheus text", () => {
  const m = new Metrics();
  m.inc("http_requests_total");
  assert.match(m.expose(), /http_requests_total 1/);
});

test("jwt rejects malformed bearer and authorizes roles", () => {
  const j = new Jwt("https://identity.dokandar.local");
  assert.equal(j.parse("Bearer not-a-jwt"), null);
  assert.equal(hasRole({ roles: ["ANALYST"] }, "ANALYST"), true);
  assert.equal(hasRole(null, "ANALYST"), false);
});
''')

    w.write("Dockerfile", '''# Multi-stage Node build; non-root runtime.
FROM node:24 AS build
WORKDIR /app
COPY package.json tsconfig.json ./
RUN npm install --no-audit --no-fund
COPY . .
RUN npm run build

FROM node:24-slim
WORKDIR /app
COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules ./node_modules
COPY package.json ./
EXPOSE %d 9090
USER node
CMD ["node", "dist/src/index.js"]
''' % svc.http_port)

    w.write(".gitlab-ci.yml", '''stages: [build, package]

node:build-test:
  stage: build
  image: node:24
  before_script:
    # consume @dokandar/platform-sdk by building the cloned SDK and linking it locally
    - apt-get update -qq && apt-get install -y -qq git >/dev/null
    - git clone --depth 1 --branch v1.0.0 "https://gitlab-ci-token:${CI_JOB_TOKEN}@gitlab.com/%s/dkd-platform-libs.git" /tmp/libs
    - (cd /tmp/libs/sdk/typescript && npm install --no-audit --no-fund && npm run build)
    - npm install --no-audit --no-fund /tmp/libs/sdk/typescript
  script:
    - npm install --no-audit --no-fund
    - npm run build
    - npm test

docker:build:
  stage: package
  image: docker:27
  services: [docker:27-dind]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  script:
    - docker build -t "$CI_REGISTRY_IMAGE:0.1.0" .
''' % svc.group)

    return list(w.written)
