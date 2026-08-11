/**
 * BFF-side auth helpers. The BFF owns the refresh lifecycle: it calls the gateway with the opaque
 * refresh token from the encrypted session cookie, rotates it, and never returns it to the browser.
 */
import "server-only";
import { randomBytes } from "node:crypto";
import { NextResponse, type NextRequest } from "next/server";
import { serverEnv } from "@/lib/env";
import type { ClientSession, TokenBundle } from "@/lib/auth";
import {
  clearSessionCookie,
  readSessionCookie,
  writeSessionCookie,
  type SessionPayload,
} from "@/lib/session";

const hex = (n: number) => randomBytes(n).toString("hex");

export async function authGatewayPost(path: string, body: unknown, rid: string): Promise<Response> {
  return fetch(`${serverEnv.GATEWAY_URL}/api/v1/auth/${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-request-id": rid, traceparent: `00-${hex(16)}-${hex(8)}-01` },
    body: JSON.stringify(body),
    cache: "no-store",
  });
}

export const sessionFromBundle = (b: TokenBundle): SessionPayload => ({
  sub: b.user.id,
  role: b.user.role,
  kyc: b.user.kyc,
  rt: b.refresh_token,
});

export const clientSession = (b: TokenBundle): ClientSession => ({
  access_token: b.access_token,
  expires_in: b.expires_in,
  user: b.user,
});

/** CSRF mitigation for cookie-authed mutations: reject cross-origin POSTs. */
export function sameOrigin(req: Request): boolean {
  const origin = req.headers.get("origin");
  if (!origin) return true; // same-origin navigations may omit Origin
  try {
    return new URL(origin).host === req.headers.get("host");
  } catch {
    return false;
  }
}

export const reqId = (req: NextRequest) => req.headers.get("x-request-id") ?? hex(16);

/** Rotate: read cookie rt → gateway /refresh → re-seal cookie with the new rt → return access token. */
export async function rotateSession(req: NextRequest): Promise<NextResponse> {
  const session = await readSessionCookie();
  if (!session) {
    return NextResponse.json({ error: { code: "unauthenticated", message: "no session" } }, { status: 401 });
  }
  const upstream = await authGatewayPost("refresh", { refresh_token: session.rt }, reqId(req));
  if (!upstream.ok) {
    await clearSessionCookie(); // refresh failed/expired → force re-login
    return NextResponse.json({ error: { code: "session_expired", message: "refresh failed" } }, { status: 401 });
  }
  const bundle = (await upstream.json()) as TokenBundle;
  await writeSessionCookie(sessionFromBundle(bundle));
  return NextResponse.json(clientSession(bundle));
}
