import { NextResponse, type NextRequest } from "next/server";
import { rotateSession, sameOrigin } from "@/lib/auth-server";

// POST → rotate the session (uses the httpOnly refresh cookie) → new access token. 401 (+ cookie cleared) on failure.
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(req: NextRequest) {
  if (!sameOrigin(req)) {
    return NextResponse.json({ error: { code: "forbidden", message: "bad origin" } }, { status: 403 });
  }
  return rotateSession(req);
}
