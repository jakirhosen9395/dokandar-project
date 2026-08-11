// Minimal dependency-free router for the /v1 REST surface: JSON body parsing with a
// strict integer guard for *Poisha fields, the {success,data,error,meta} envelope,
// RFC-7807 problem+json errors with the dokandar.b2c.* taxonomy, Idempotency-Key extraction.
import type { IncomingMessage, ServerResponse } from "node:http";
import { stringifyWithBigInt } from "../domain/json.js";

export class ApiError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) {
    super(message);
  }
}

export interface ReqCtx {
  params: Record<string, string>;
  query: URLSearchParams;
  body: Record<string, unknown>;
  idemKey: string | null;
}

export type Handler = (ctx: ReqCtx) => Promise<{ status?: number; data: unknown; meta?: unknown }>;

interface Route { method: string; parts: string[]; handler: Handler }

export class Router {
  private routes: Route[] = [];

  on(method: string, path: string, handler: Handler): void {
    this.routes.push({ method, parts: path.split("/").filter(Boolean), handler });
  }

  /** @returns true when the request matched a route (response already written). */
  async dispatch(req: IncomingMessage, res: ServerResponse): Promise<boolean> {
    const url = new URL(req.url ?? "/", "http://local");
    const parts = url.pathname.split("/").filter(Boolean);
    for (const r of this.routes) {
      if (r.method !== req.method || r.parts.length !== parts.length) continue;
      const params: Record<string, string> = {};
      let ok = true;
      for (let i = 0; i < r.parts.length; i++) {
        const p = r.parts[i];
        if (p.startsWith(":")) params[p.slice(1)] = decodeURIComponent(parts[i]);
        else if (p !== parts[i]) { ok = false; break; }
      }
      if (!ok) continue;
      try {
        const body = req.method === "GET" ? {} : await readJson(req);
        const idemKey = (req.headers["idempotency-key"] as string | undefined)?.trim() || null;
        const out = await r.handler({ params, query: url.searchParams, body, idemKey });
        writeEnvelope(res, out.status ?? 200, out.data, out.meta ?? null);
      } catch (e) {
        writeProblem(res, e);
      }
      return true;
    }
    return false;
  }
}

const MAX_BODY_BYTES = 262_144; // 256 KB — far above any legal payload on this surface

async function readJson(req: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const c of req) {
    size += (c as Buffer).length;
    if (size > MAX_BODY_BYTES)
      throw new ApiError(413, "dokandar.b2c.request.body_too_large", "request body exceeds 256 KB");
    chunks.push(c as Buffer);
  }
  const raw = Buffer.concat(chunks).toString("utf8");
  if (raw.trim() === "") return {};
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new ApiError(400, "dokandar.b2c.request.malformed", "request body is not valid JSON");
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed))
    throw new ApiError(400, "dokandar.b2c.request.malformed", "request body must be a JSON object");
  assertIntegerPoisha(parsed as Record<string, unknown>);
  return parsed as Record<string, unknown>;
}

/** B2C-12 / EF-API-10: strict-reject a write body carrying any field outside its allow-list. */
export function rejectUnknownFields(obj: Record<string, unknown>, allowed: readonly string[]): void {
  for (const k of Object.keys(obj)) {
    if (!allowed.includes(k))
      throw new ApiError(422, "dokandar.b2c.request.unknown_field", `unknown field not accepted: ${k}`);
  }
}

/** Integer-poisha lint at the boundary: any *Poisha field must be a JSON integer (recursive). */
export function assertIntegerPoisha(obj: Record<string, unknown>, depth = 0): void {
  if (depth > 20)
    throw new ApiError(400, "dokandar.b2c.request.too_deep", "request nesting exceeds a safe depth");
  for (const [k, v] of Object.entries(obj)) {
    if (k.endsWith("Poisha")) {
      if (typeof v !== "number" || !Number.isInteger(v))
        throw new ApiError(400, "dokandar.b2c.request.money_not_integer",
          `${k} must be an integer number of poisha`);
      if (!Number.isSafeInteger(v))
        throw new ApiError(400, "dokandar.b2c.request.money_unsafe_integer",
          `${k} exceeds the safe integer range`);
    } else if (typeof v === "object" && v !== null && !Array.isArray(v)) {
      assertIntegerPoisha(v as Record<string, unknown>, depth + 1);
    } else if (Array.isArray(v)) {
      for (const item of v)
        if (typeof item === "object" && item !== null)
          assertIntegerPoisha(item as Record<string, unknown>, depth + 1);
    }
  }
}

export function writeEnvelope(res: ServerResponse, status: number, data: unknown, meta: unknown): void {
  res.writeHead(status, { "Content-Type": "application/json" });
  // stringifyWithBigInt keeps poisha as exact integer literals in REST responses too (CC-CONS-03).
  res.end(stringifyWithBigInt({ success: true, data, error: null, meta }));
}

export function writeProblem(res: ServerResponse, e: unknown): void {
  const err = e instanceof ApiError ? e
    : new ApiError(500, "dokandar.b2c.internal.unexpected", "internal error — see service logs");
  // Unexpected (non-ApiError) 500s were previously invisible — surface the real cause on stderr.
  if (!(e instanceof ApiError))
    process.stderr.write(JSON.stringify({ level: "error", msg: "unexpected request error",
      err: e instanceof Error ? e.stack ?? e.message : String(e) }) + "\n");
  res.writeHead(err.status, { "Content-Type": "application/problem+json" });
  res.end(JSON.stringify({
    success: false, data: null,
    error: { type: "about:blank", title: err.status >= 500 ? "Internal Server Error" : "Request Rejected",
             status: err.status, code: err.code, detail: err.message },
    meta: null,
  }));
}

export function requireIdemKey(ctx: ReqCtx): string {
  if (!ctx.idemKey)
    throw new ApiError(400, "dokandar.b2c.request.missing_idempotency_key",
      "Idempotency-Key header is mandatory on b2c writes");
  return ctx.idemKey;
}
