/**
 * Operational metadata for /health /ready /data — mirrors the backend identity block.
 * The OpenAPI MANIFEST is statically imported so it is bundled (works in the standalone Docker build,
 * where a runtime fs read of generated/ would not be traced). No secrets are exposed.
 */
import { createRequire } from "node:module";
import manifest from "@/generated/openapi/MANIFEST.json";
import { publicEnv, serverEnv } from "@/lib/env";

const require_ = createRequire(import.meta.url);
const BOOT_MS = Date.now();

export interface ManifestEntry {
  version: string | null;
  title: string | null;
  paths: number;
  source: string;
  fetchedAt: string;
}
export const generatedApi = manifest as Record<string, ManifestEntry>;

export function identity() {
  return {
    service_name: "dokandar-web",
    version: process.env.CODE_VERSION || "0.1.0",
    environment: serverEnv.APP_ENV,
    uptime_seconds: Math.floor((Date.now() - BOOT_MS) / 1000),
  };
}

export function nextVersion(): string {
  try {
    return (require_("next/package.json") as { version: string }).version;
  } catch {
    return "unknown";
  }
}

/** Mask host so the gateway address is never disclosed in /data. */
export function maskGatewayUrl(): string {
  try {
    const u = new URL(serverEnv.GATEWAY_URL);
    return `${u.protocol}//***:${u.port || "(default)"}`;
  } catch {
    return "***";
  }
}

export async function checkGateway(timeoutMs = 4000): Promise<boolean> {
  try {
    const r = await fetch(`${serverEnv.GATEWAY_URL}/ready`, {
      cache: "no-store",
      signal: AbortSignal.timeout(timeoutMs),
    });
    return r.ok;
  } catch {
    return false;
  }
}

export function observabilityStatus() {
  return {
    rum_enabled: !!publicEnv.RUM_SERVER_URL,
    rum_service_name: publicEnv.RUM_SERVICE_NAME,
    trace_propagation: "bff-traceparent-injection",
  };
}
