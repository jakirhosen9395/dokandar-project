import { NextResponse, type NextRequest } from "next/server";
import { authGatewayPost, reqId, sameOrigin } from "@/lib/auth-server";
import { clearSessionCookie, readSessionCookie } from "@/lib/session";

// POST → revoke the refresh token at the gateway (idempotent) and clear the session cookie.
// "Logout everywhere" = the refresh token is revoked server-side, so no tab can refresh after this.
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(req: NextRequest) {
  if (!sameOrigin(req)) {
    return NextResponse.json({ error: { code: "forbidden", message: "bad origin" } }, { status: 403 });
  }
  const session = await readSessionCookie();
  if (session) {
    await authGatewayPost("logout", { refresh_token: session.rt }, reqId(req)).catch(() => {});
  }
  await clearSessionCookie();
  return NextResponse.json({ ok: true });
}
