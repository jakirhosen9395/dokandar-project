/**
 * Server-enforced RBAC (Edge middleware). Reads the encrypted httpOnly session cookie (no client trust):
 *   - no session  → redirect to /login?next=…   (unauthorized)
 *   - wrong role  → rewrite to /forbidden        (403 page; URL preserved)
 * Roles: customer · shopkeeper · shop_staff · platform_staff · admin (verified from the JWT role claim).
 */
import { NextResponse, type NextRequest } from "next/server";
import type { Role } from "@/lib/auth";
import { ROLE_GATES } from "@/lib/auth";
import { SESSION_COOKIE, openSession } from "@/lib/session-core";

export async function middleware(req: NextRequest): Promise<NextResponse> {
  const { pathname } = req.nextUrl;
  const gate = Object.entries(ROLE_GATES).find(
    ([prefix]) => pathname === prefix || pathname.startsWith(prefix + "/"),
  );
  if (!gate) return NextResponse.next();
  const [, allowed] = gate as [string, Role[]];

  const raw = req.cookies.get(SESSION_COOKIE)?.value;
  const session = raw ? await openSession(raw) : null;

  if (!session) {
    const url = req.nextUrl.clone();
    url.pathname = "/login";
    url.searchParams.set("next", pathname);
    return NextResponse.redirect(url);
  }
  if (!allowed.includes(session.role)) {
    const url = req.nextUrl.clone();
    url.pathname = "/forbidden";
    return NextResponse.rewrite(url);
  }
  return NextResponse.next();
}

export const config = {
  matcher: ["/devops/:path*", "/admin/:path*", "/seller/:path*", "/account/:path*"],
};
