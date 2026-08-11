/**
 * BFF gateway proxy — the ONLY way the browser reaches the backend.
 *
 *   Browser → /api/gw/<svc>/<...>  →  (this handler, server-side)  →  GATEWAY_URL/api/v1/<svc>/<...>
 *
 * The gateway base URL is server-only (lib/env). The browser never learns it. The handler:
 *  - forwards method/body/query and the client Authorization header (access token lives in memory client-side),
 *  - mints/propagates `x-request-id` and a W3C `traceparent` so frontend↔gateway↔service share one trace
 *    (resolves the gateway CORS `traceparent` gap by injecting it server-side — see FRONTEND_ARCHITECTURE §12),
 *  - strips hop-by-hop headers.
 *
 * Auth wiring (login/refresh, httpOnly refresh cookie) lands in Phase 2; this is the transport foundation.
 */
import type { NextRequest } from "next/server";
import { randomBytes } from "node:crypto";
import { serverEnv } from "@/lib/env";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const HOP_BY_HOP = new Set([
  "host", "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
  "te", "trailer", "transfer-encoding", "upgrade", "content-length", "accept-encoding",
]);

function hex(n: number): string {
  return randomBytes(n).toString("hex");
}

async function proxy(req: NextRequest, ctx: { params: Promise<{ path: string[] }> }): Promise<Response> {
  const { path } = await ctx.params;
  const target = `${serverEnv.GATEWAY_URL}/api/v1/${path.join("/")}${req.nextUrl.search}`;

  const headers = new Headers();
  req.headers.forEach((value, key) => {
    if (!HOP_BY_HOP.has(key.toLowerCase())) headers.set(key, value);
  });

  const requestId = req.headers.get("x-request-id") ?? hex(16);
  headers.set("x-request-id", requestId);
  // Continue the browser RUM trace if present; otherwise start one (W3C traceparent: version-traceid-spanid-flags).
  if (!headers.has("traceparent")) headers.set("traceparent", `00-${hex(16)}-${hex(8)}-01`);

  const init: RequestInit = { method: req.method, headers, redirect: "manual", cache: "no-store" };
  if (req.method !== "GET" && req.method !== "HEAD") init.body = await req.arrayBuffer();

  let upstream: Response;
  try {
    upstream = await fetch(target, init);
  } catch {
    return Response.json(
      { error: { code: "gateway_unreachable", message: "API gateway is unreachable", request_id: requestId } },
      { status: 502 },
    );
  }

  const out = new Headers(upstream.headers);
  out.delete("content-encoding");
  out.delete("transfer-encoding");
  out.set("x-request-id", requestId);
  return new Response(upstream.body, { status: upstream.status, headers: out });
}

export const GET = proxy;
export const POST = proxy;
export const PUT = proxy;
export const PATCH = proxy;
export const DELETE = proxy;
export const HEAD = proxy;
export const OPTIONS = proxy;
