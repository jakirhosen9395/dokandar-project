"""
dkdgen.emitters.typescript_emit — emits the TypeScript SDK from the IR.

Mirrors the Python reference emitter (identical semantics), idiomatic strict TypeScript (ESM,
NodeNext). Money/Timestamp use bigint (int64). Framework-only for contract-deferred data.
"""
from __future__ import annotations
import json
from ..ir import Contracts, CONTEXTS
from .base import Writer, pascal, camel, screaming, const_name

LANG = "typescript"


def _q(s) -> str:
    return json.dumps(s)


def emit(c: Contracts, meta: dict, out_dir: str) -> list[str]:
    w = Writer(out_dir, "//", meta)

    # provenance
    w.write("src/provenance.ts",
            "export const GENERATOR = %s;\nexport const GENERATOR_VERSION = %s;\n"
            "export const CONTRACT_VERSION = %s;\nexport const BUILD_TIME = %s;\nexport const BUILD_COMMIT = %s;\n" % (
                _q(meta["generator"]), _q(meta["generator_version"]), _q(meta["contract_version"]),
                _q(meta["build_time"]), _q(meta["build_commit"])))

    # money / time (int64 -> bigint)
    w.write("src/money.ts", '''export const POISHA_PER_BDT = 100n;

/** Money is int64 poisha (bigint). Float/decimal/string money is banned (DM type conventions). */
export class Money {
  constructor(public readonly poisha: bigint) {
    if (typeof poisha !== "bigint") {
      throw new TypeError("Money must be a bigint poisha");
    }
  }
  static ofBdt(bdt: bigint): Money {
    return new Money(bdt * POISHA_PER_BDT);
  }
  equals(o: Money): boolean { return o instanceof Money && o.poisha === this.poisha; }
  toString(): string { return `Money(${this.poisha} poisha)`; }
}

/** Unix milliseconds, UTC (int64). */
export class Timestamp {
  constructor(public readonly epochMs: bigint) {
    if (typeof epochMs !== "bigint") {
      throw new TypeError("Timestamp must be a bigint epochMs");
    }
  }
}
''')

    # ids
    id_lines = ["/** Strongly-typed identifiers (ids.yaml). No raw-string IDs. */", ""]
    id_lines += [
        "export abstract class PrefixedId {",
        "  static readonly PREFIX: string = \"\";",
        "  static readonly OWNER_CONTEXT: number = 0;",
        "  static readonly IMMUTABLE: boolean = false;",
        "  constructor(public readonly value: string) {",
        "    const prefix = (this.constructor as typeof PrefixedId).PREFIX;",
        "    if (typeof value !== \"string\" || !value.startsWith(prefix) || value.length <= prefix.length) {",
        "      throw new Error(`${this.constructor.name} must start with '${prefix}' and carry a body`);",
        "    }",
        "  }",
        "  toString(): string { return this.value; }",
        "}",
        "",
    ]
    for i in c.identifiers:
        cls = pascal(i.id)
        id_lines += [
            "export class %s extends PrefixedId {" % cls,
            "  static override readonly PREFIX = %s;" % _q(i.prefix),
            "  static override readonly OWNER_CONTEXT = %d; // %s" % (i.owner_ctx, CONTEXTS[i.owner_ctx]),
            "  static override readonly IMMUTABLE = %s;" % ("true" if i.immutable else "false"),
            "}",
            "",
        ]
    w.write("src/ids.ts", "\n".join(id_lines))

    # topics / events
    t_lines = ["/** Kafka topics + RabbitMQ queues (messaging.yaml). Cross-context = Kafka only (R6). */", "",
               "export interface TopicMeta {",
               "  readonly name: string; readonly producer: number; readonly key: string;",
               "  readonly consumers: readonly number[]; readonly context: string;",
               "  readonly aggregate: string; readonly event: string; readonly version: number;",
               "}", "",
               "export const KafkaTopics = {"]
    for t in c.topics:
        t_lines.append("  %s: %s," % (const_name(t.name), _q(t.name)))
    t_lines += ["} as const;", "", "export const RabbitQueues = {"]
    for q in c.queues:
        t_lines.append("  %s: %s," % (screaming(q.name), _q(q.name)))
    t_lines += ["} as const;", "", "export const TOPIC_META: Readonly<Record<string, TopicMeta>> = {"]
    for t in c.topics:
        t_lines.append("  %s: { name: %s, producer: %d, key: %s, consumers: %s, context: %s, aggregate: %s, event: %s, version: %d }," % (
            _q(t.name), _q(t.name), t.producer, _q(t.key), json.dumps(list(t.consumers)),
            _q(t.context), _q(t.aggregate), _q(t.event), t.version))
    t_lines += ["};", "",
                "export function topicMeta(name: string): TopicMeta {",
                "  const m = TOPIC_META[name];",
                "  if (!m) throw new Error(`unknown topic: ${name}`);",
                "  return m;",
                "}",
                "",
                "export const ALL_TOPICS: readonly string[] = Object.keys(TOPIC_META);"]
    w.write("src/topics.ts", "\n".join(t_lines))

    # config
    cfg = ["/** Canon-named operational constants (configuration.yaml). Values verbatim from canon. */", ""]
    for k in c.constants:
        val = k.value
        lit = ("%dn" % val) if isinstance(val, int) and not isinstance(val, bool) else _q(val)
        cfg.append("export const %s = %s; // %s — %s" % (screaming(k.id), lit, k.human, k.scope))
    w.write("src/config.ts", "\n".join(cfg))

    # enums (string enums)
    e = ["/** Canonical enum families (glossary.yaml; FR-IDN-310). Values transcribed verbatim. */", ""]
    for f in c.enum_families:
        if not f.values:
            continue
        cls = pascal(f.family)
        e += ["export enum %s {" % cls]
        for v in f.values:
            e.append("  %s = %s," % (screaming(v), _q(v)))
        e.append("}")
        if f.exhaustive is not True:
            e.append("// NOTE: contract marks this family non-exhaustive (illustrative).")
        e.append("")
    w.write("src/enums.ts", "\n".join(e))

    # errors
    slugs = list(c.error_taxonomy.context_slugs)
    err = ['/** Error taxonomy (error-codes.yaml): dokandar.<context>.<category>.<reason> (RFC-7807).',
           ' * Concrete codes are NEEDS-INFO in the frozen contracts, so this provides the builder +',
           ' * context-slug enum + exception hierarchy + ProblemDetails — never a fabricated code list. */', '']
    err += ["export enum ContextSlug {"]
    for s in slugs:
        err.append("  %s = %s," % (screaming(s), _q(s)))
    err += ["}", "",
            "export const CONTEXT_SLUGS: readonly string[] = %s;" % json.dumps(slugs),
            "const CODE_RE = /^dokandar\\.([a-z]+)\\.([a-z0-9_]+)\\.([a-z0-9_]+)$/;", "",
            "export function errorCode(context: string, category: string, reason: string): string {",
            "  const code = `dokandar.${context}.${category}.${reason}`;",
            "  if (!CONTEXT_SLUGS.includes(context)) throw new Error(`unknown context slug: ${context}`);",
            "  if (!CODE_RE.test(code)) throw new Error(`error code violates taxonomy: ${code}`);",
            "  return code;",
            "}", "",
            "export interface ProblemDetails {",
            "  type: string; title: string; status: number; code: string;",
            "  detail?: string; instance?: string; traceId?: string;",
            "}", "",
            "export class DokandarError extends Error {",
            "  readonly httpStatus: number = 500;",
            "  constructor(public readonly code: string, message: string, public readonly detail?: string) {",
            "    super(message);",
            "    this.name = new.target.name;",
            "  }",
            "  toProblem(): ProblemDetails {",
            "    return { type: \"about:blank\", title: this.message, status: this.httpStatus, code: this.code, detail: this.detail };",
            "  }",
            "}",
            "export class ValidationError extends DokandarError { override readonly httpStatus = 400; }",
            "export class BusinessError extends DokandarError { override readonly httpStatus = 409; }",
            "export class InfrastructureError extends DokandarError { override readonly httpStatus = 503; }"]
    w.write("src/errors.ts", "\n".join(err))

    # dto
    w.write("src/dto.ts", '''import type { ProblemDetails } from "./errors.js";

/** Common DTOs: the {success,data,error,meta} envelope, cursor pagination, trace/audit metadata. */
export interface PageMeta { nextCursor?: string; hasMore: boolean; limit: number; }
export interface TraceMetadata { traceId?: string; spanId?: string; correlationId?: string; }
export interface AuditMetadata { actorDid?: string; occurredAtMs?: number; requestId?: string; }
export interface Meta { page?: PageMeta; trace?: TraceMetadata; extra?: Record<string, unknown>; }

export interface Response<T> {
  success: boolean;
  data?: T;
  error?: ProblemDetails;
  meta?: Meta;
}
export function ok<T>(data: T, meta?: Meta): Response<T> { return { success: true, data, meta }; }
export function fail<T>(error: ProblemDetails, meta?: Meta): Response<T> { return { success: false, error, meta }; }

export interface Page<T> { items: T[]; page: PageMeta; }
''')

    # events
    w.write("src/events.ts", '''import { topicMeta, type TopicMeta } from "./topics.js";

/** Event envelope/base + headers + metadata + topic binding + serializer interface.
 * Per-event PAYLOAD types are FRAMEWORK-ONLY (schema-registry.yaml subjects are NEEDS-INFO):
 * EventEnvelope is generic over the payload; concrete payloads bind on Phase-2 contract population. */
export interface EventHeaders {
  eventId: string;          // inbox dedup key
  occurredAtMs: number;
  producerContext: number;
  partitionKey: string;     // per-aggregate ordering key
  correlationId?: string;
  traceId?: string;
  schemaVersion: number;
}

export interface EventMetadata { topic: string; meta: TopicMeta; }
export function eventMetadataFor(topic: string): EventMetadata {
  return { topic, meta: topicMeta(topic) };
}

export interface EventEnvelope<P> {
  headers: EventHeaders;
  topic: string;
  payload: P;               // contract-populated in Phase 2 (NEEDS-INFO)
}

export interface PayloadSerializer<P> {
  serialize(payload: P): Uint8Array;
  deserialize(data: Uint8Array): P;
}
''')

    # schema
    s_lines = ['/** Schema-registry metadata (schema-registry.yaml): subjects + compatibility + version helpers.',
               ' * Per-subject JSON-Schema is NEEDS-INFO, so getSchema() is an extension point that throws',
               ' * until populated — never a fabricated schema. */', '',
               "export enum Compatibility { BACKWARD = \"BACKWARD\" }", "",
               "export interface SubjectInfo { subject: string; topic: string; compatibility: string; schemaStatus: string; }", "",
               "export const SUBJECTS: Readonly<Record<string, SubjectInfo>> = {"]
    for s in c.schema_subjects:
        s_lines.append("  %s: { subject: %s, topic: %s, compatibility: %s, schemaStatus: %s }," % (
            _q(s.subject), _q(s.subject), _q(s.topic), _q(s.compatibility), _q(s.schema_status)))
    s_lines += ["};", "",
                "export function subjectFor(topic: string): string {",
                "  const s = SUBJECTS[topic];",
                "  if (!s) throw new Error(`no subject for topic: ${topic}`);",
                "  return s.subject;",
                "}",
                "export function getSchema(subject: string): never {",
                "  throw new Error(`schema for ${subject} is NEEDS-INFO in frozen contracts (Phase-2 transcription)`);",
                "}",
                "export function isCompatible(newVersion: number, oldVersion: number): boolean {",
                "  return newVersion >= oldVersion; // BACKWARD within a major (EF §8.4)",
                "}"]
    w.write("src/schema.ts", "\n".join(s_lines))

    # security
    # Role families are the canonical glossary enums (./enums.ts: KycTiers / OversightRoles /
    # EnforcementActions), exported at the package root. They are defined once (in enums) — not here.
    sec = ['/** Security helpers: access principles, JWT claim names, correlation/trace propagation.',
           ' * Role families live in ./enums.ts (one source per symbol; exported at the package root).',
           ' * The permission MATRIX is NEEDS-INFO (permissions.yaml) — principle constants only. */', '']
    sec += ["export const PRINCIPLES: Readonly<Record<string, string>> = {"]
    for p in c.principles:
        sec.append("  %s: %s," % (_q(p.id), _q(p.rule)))
    sec += ["};", "",
            "export const JwtClaims = {",
            "  SUBJECT_DID: \"sub\", KYC_TIER: \"kyc_tier\", ROLES: \"roles\", CORRELATION_ID: \"cid\",",
            "} as const;", "",
            "export class CorrelationContext {",
            "  constructor(public correlationId?: string, public traceId?: string, public actorDid?: string) {}",
            "  headers(): Record<string, string> {",
            "    const h: Record<string, string> = {};",
            "    if (this.correlationId) h[\"x-correlation-id\"] = this.correlationId;",
            "    if (this.traceId) h[\"traceparent\"] = this.traceId;",
            "    return h;",
            "  }",
            "}"]
    w.write("src/security.ts", "\n".join(sec))

    # validation
    w.write("src/validation.ts", '''import { PrefixedId } from "./ids.js";
import { Money } from "./money.js";
import { TOPIC_META } from "./topics.js";

type IdCtor<T extends PrefixedId> = new (value: string) => T;

export function validateId<T extends PrefixedId>(ctor: IdCtor<T>, value: string): T {
  return new ctor(value);
}
export function isValidId<T extends PrefixedId>(ctor: IdCtor<T>, value: string): boolean {
  try { new ctor(value); return true; } catch { return false; }
}
export function validateMoney(poisha: bigint): Money { return new Money(poisha); }
export function validateTopic(name: string): boolean { return name in TOPIC_META; }
''')

    # API Documentation Standard helper — serves Swagger UI at /docs and the OpenAPI JSON at
    # /swagger/v1/swagger.json so Node services inherit identical docs via one handleDocs(...) call.
    w.write("src/apidocs.ts", '''import type { IncomingMessage, ServerResponse } from "node:http";

// Content-Security-Policy for the Swagger UI paths (allows the UI assets it loads).
export const DOCS_CSP =
  "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; " +
  "style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; img-src 'self' data: https://cdn.jsdelivr.net; " +
  "font-src 'self' https://cdn.jsdelivr.net; connect-src 'self'";

export function isDocsPath(path: string): boolean {
  return path.startsWith("/docs") || path.startsWith("/swagger");
}

const SWAGGER_UI_HTML = `<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><title>API Documentation</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/swagger-ui-dist/swagger-ui.css"></head>
<body><div id="swagger-ui"></div>
<script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist/swagger-ui-bundle.js"></script>
<script>window.ui = SwaggerUIBundle({ url: "/swagger/v1/swagger.json", dom_id: "#swagger-ui" });</script>
</body></html>`;

function openapiSpec(title: string): string {
  return JSON.stringify({
    openapi: "3.0.3",
    info: { title, version: "v1", description: title + " REST API." },
    paths: {
      "/health": { get: { tags: ["HealthEndpoints"], operationId: "getHealth", summary: "Health probe", responses: { "200": { description: "OK", content: { "application/json": { schema: { $ref: "#/components/schemas/Envelope" } } } } } } },
      "/live": { get: { tags: ["HealthEndpoints"], operationId: "getLive", summary: "Liveness probe", responses: { "200": { description: "OK" } } } },
      "/ready": { get: { tags: ["HealthEndpoints"], operationId: "getReady", summary: "Readiness probe", responses: { "200": { description: "OK" }, "503": { description: "Not ready", content: { "application/problem+json": { schema: { $ref: "#/components/schemas/ProblemDetails" } } } } } } },
      "/version": { get: { tags: ["HealthEndpoints"], operationId: "getVersion", summary: "Version", responses: { "200": { description: "OK", content: { "application/json": { schema: { $ref: "#/components/schemas/Envelope" } } } } } } },
    },
    components: {
      schemas: {
        Envelope: { type: "object", properties: { success: { type: "boolean" }, data: { type: "object", nullable: true }, error: { $ref: "#/components/schemas/ProblemDetails" }, meta: { type: "object", nullable: true } } },
        ProblemDetails: { type: "object", description: "RFC-7807 problem+json", properties: { type: { type: "string" }, title: { type: "string" }, status: { type: "integer" }, detail: { type: "string" }, instance: { type: "string" }, code: { type: "string" } } },
      },
      securitySchemes: { Bearer: { type: "http", scheme: "bearer", bearerFormat: "JWT", description: "JWT bearer token (injected by the API gateway in production)." } },
    },
  });
}

// handleDocs serves /docs and /swagger/v1/swagger.json; returns true when it handled the request.
export function handleDocs(req: IncomingMessage, res: ServerResponse, title: string): boolean {
  const url = req.url ?? "";
  if (url === "/docs") {
    res.statusCode = 200;
    res.setHeader("Content-Type", "text/html; charset=utf-8");
    res.end(SWAGGER_UI_HTML);
    return true;
  }
  if (url === "/swagger/v1/swagger.json") {
    res.statusCode = 200;
    res.setHeader("Content-Type", "application/json");
    res.end(openapiSpec(title));
    return true;
  }
  return false;
}
''')

    # index
    w.write("src/index.ts",
            "// dkd_platform — generated DOKANDAR platform SDK (TypeScript).\n"
            + "\n".join("export * from %s;" % _q("./%s.js" % m) for m in
                        ["provenance", "money", "ids", "topics", "config", "enums", "errors",
                         "dto", "events", "schema", "security", "validation", "apidocs"]) + "\n")

    # package.json + tsconfig (no banner)
    w.write("package.json", json.dumps({
        "name": "@dokandar/platform-sdk",
        "version": meta["contract_version"],
        "description": "DOKANDAR platform SDK (TypeScript) — generated from dkd-contracts-spine",
        "type": "module",
        "main": "dist/src/index.js",
        "types": "dist/src/index.d.ts",
        "scripts": {"build": "tsc -p tsconfig.json", "test": "tsc -p tsconfig.json && node --test dist/test/sdk.test.js"},
        "license": "UNLICENSED",
        "devDependencies": {"typescript": "^5.7.0", "@types/node": "^24.0.0"},
    }, indent=2) + "\n", with_banner=False)

    w.write("tsconfig.json", json.dumps({
        "compilerOptions": {
            "target": "ES2022", "module": "NodeNext", "moduleResolution": "NodeNext",
            "strict": True, "declaration": True, "outDir": "dist", "rootDir": ".",
            "esModuleInterop": True, "skipLibCheck": True, "forceConsistentCasingInFileNames": True,
        },
        "include": ["src/**/*.ts", "test/**/*.ts"],
    }, indent=2) + "\n", with_banner=False)

    # test (node:test)
    w.write("test/sdk.test.ts", '''import { test } from "node:test";
import assert from "node:assert/strict";
import { CONTRACT_VERSION } from "../src/provenance.js";
import { DID, PPID } from "../src/ids.js";
import { Money } from "../src/money.js";
import { TOPIC_META, RabbitQueues } from "../src/topics.js";
import { errorCode, ContextSlug } from "../src/errors.js";

test("provenance", () => { assert.equal(CONTRACT_VERSION, %s); });

test("ids typed + validated", () => {
  const d = new DID("did:dokandar:abc");
  assert.equal(d.toString(), "did:dokandar:abc");
  assert.equal(DID.IMMUTABLE, true);
  assert.equal(DID.OWNER_CONTEXT, 1);
  assert.throws(() => new PPID("did:dokandar:x"));
});

test("topics: 59 with metadata", () => {
  assert.equal(Object.keys(TOPIC_META).length, 59);
  assert.equal(TOPIC_META["custody.passport.CustodyInitialized.v1"].producer, 3);
  assert.equal(Object.keys(RabbitQueues).length, 10);
});

test("money is bigint int64", () => {
  assert.equal(new Money(5000n).poisha, 5000n);
  assert.throws(() => new Money(50 as unknown as bigint));
});

test("error taxonomy", () => {
  assert.equal(errorCode("finance", "idempotency", "duplicate_key"), "dokandar.finance.idempotency.duplicate_key");
  assert.throws(() => errorCode("frobnicate", "x", "y"));
  assert.equal(ContextSlug.FINANCE, "finance");
});
''' % _q(meta["contract_version"]), with_banner=False)

    return list(w.written)
