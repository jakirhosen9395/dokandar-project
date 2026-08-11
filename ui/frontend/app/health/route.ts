import { NextResponse } from "next/server";
import { identity } from "@/lib/ops";

// Liveness — lightweight; 200 whenever the process can serve. No dependency checks (see /ready).
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export function GET() {
  return NextResponse.json({ status: "healthy", ...identity() }, { status: 200 });
}
