import { NextResponse } from "next/server";
import { serverEnv } from "@/lib/env";
import { checkGateway, generatedApi, identity } from "@/lib/ops";

// Readiness — verifies traffic-critical deps: API Gateway reachable, required env present,
// OpenAPI manifest available. Returns 503 if any is unavailable (LB/orchestrator should not route).
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  const env_ok = serverEnv.GATEWAY_URL.length > 0;
  const manifest_services = Object.keys(generatedApi).length;
  const manifest_ok = manifest_services > 0;
  const gateway_ok = await checkGateway();

  const ready = env_ok && manifest_ok && gateway_ok;
  return NextResponse.json(
    {
      status: ready ? "ready" : "not_ready",
      ...identity(),
      checks: {
        gateway: { ok: gateway_ok, detail: gateway_ok ? "reachable" : "unreachable" },
        env: { ok: env_ok, detail: env_ok ? "GATEWAY_URL set" : "GATEWAY_URL missing" },
        openapi_manifest: { ok: manifest_ok, services: manifest_services },
      },
    },
    { status: ready ? 200 : 503 },
  );
}
