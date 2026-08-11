import { NextResponse, type NextRequest } from "next/server";
import type { TokenBundle } from "@/lib/auth";
import { authGatewayPost, clientSession, reqId, sameOrigin, sessionFromBundle } from "@/lib/auth-server";
import { writeSessionCookie } from "@/lib/session";

// POST { mode: "login"|"signup", phone, code, [name, lang, role, email] }
// → gateway /<mode>/verify → seal session cookie (httpOnly, encrypted) → return access token + user (NO refresh token).
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(req: NextRequest) {
  if (!sameOrigin(req)) {
    return NextResponse.json({ error: { code: "forbidden", message: "bad origin" } }, { status: 403 });
  }
  const { mode, ...payload } = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  const flow = mode === "signup" ? "signup" : "login";
  const upstream = await authGatewayPost(`${flow}/verify`, payload, reqId(req));
  if (!upstream.ok) {
    return new NextResponse(await upstream.text(), {
      status: upstream.status,
      headers: { "content-type": "application/json" },
    });
  }
  const bundle = (await upstream.json()) as TokenBundle;
  await writeSessionCookie(sessionFromBundle(bundle));
  return NextResponse.json(clientSession(bundle));
}
