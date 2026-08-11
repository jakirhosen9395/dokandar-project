import { NextResponse } from "next/server";
import { generatedApi, identity, maskGatewayUrl, nextVersion, observabilityStatus } from "@/lib/ops";

// Operational metadata (backend-parity /data). Secrets are never exposed; gateway_url is masked.
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export function GET() {
  return NextResponse.json({
    ...identity(),
    build_time: process.env.BUILD_TIME || "unknown",
    git_commit: process.env.GIT_COMMIT || "unknown",
    node_version: process.version,
    next_version: nextVersion(),
    gateway_url: maskGatewayUrl(),
    observability: observabilityStatus(),
    generated_api: {
      services: Object.keys(generatedApi).length,
      versions: Object.fromEntries(
        Object.entries(generatedApi).map(([svc, m]) => [svc, m.version]),
      ),
    },
  });
}
