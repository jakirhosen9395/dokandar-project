import { type NextRequest } from "next/server";
import { rotateSession } from "@/lib/auth-server";

// GET → silent bootstrap on page load / new tab: if the httpOnly session cookie is valid, mint a fresh
// access token (rotating the refresh cookie) and return it; otherwise 401. The browser keeps the access
// token in memory only, so every cold load restores the session from the cookie via this endpoint.
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(req: NextRequest) {
  return rotateSession(req);
}
