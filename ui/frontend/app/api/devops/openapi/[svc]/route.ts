import { type NextRequest, NextResponse } from "next/server";
import { openSession, SESSION_COOKIE } from "@/lib/session-core";
import { serverEnv } from "@/lib/env";
import { SERVICES } from "@/content/devops/services";

export const runtime = "nodejs";

// Server-side OpenAPI proxy for the DEVOPS API Explorer. Role-guarded (admin/platform_staff) because
// this route sits outside the middleware matcher. The internal SPEC_HOST:port is never sent to the browser.
export async function GET(req: NextRequest, { params }: { params: Promise<{ svc: string }> }) {
  const session = await openSession(req.cookies.get(SESSION_COOKIE)?.value ?? "");
  if (!session) return new NextResponse(null, { status: 401 });
  if (session.role !== "admin" && session.role !== "platform_staff") return new NextResponse(null, { status: 403 });

  const { svc } = await params;
  const entry = SERVICES.find((s) => s.id === svc);
  if (!entry) return new NextResponse(null, { status: 404 });

  try {
    const r = await fetch(`http://${serverEnv.SPEC_HOST}:${entry.externalRest}/openapi.json`, { signal: AbortSignal.timeout(6000) });
    if (!r.ok) return NextResponse.json({ error: { code: "upstream", message: `${svc} openapi ${r.status}` } }, { status: 502 });
    return NextResponse.json(await r.json());
  } catch {
    return NextResponse.json({ error: { code: "unreachable", message: `${svc} openapi unreachable` } }, { status: 502 });
  }
}
