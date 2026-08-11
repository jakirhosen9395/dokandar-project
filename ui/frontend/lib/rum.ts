/**
 * Elastic RUM (browser) — initialized client-side only when NEXT_PUBLIC_RUM_SERVER_URL is configured,
 * so the build/run works without an APM endpoint. RUM starts the browser trace; the BFF continues it
 * (traceparent) to the gateway → service, giving one trace across Frontend → BFF → Gateway → Service
 * in the same Elastic APM the backend uses. User/session context is attached after login (Phase 2).
 */
import { publicEnv } from "@/lib/env";

let started = false;

export async function initRum(): Promise<void> {
  if (started || typeof window === "undefined" || !publicEnv.RUM_SERVER_URL) return;
  started = true;
  const { init } = await import("@elastic/apm-rum");
  init({
    serviceName: publicEnv.RUM_SERVICE_NAME,
    serverUrl: publicEnv.RUM_SERVER_URL,
    environment: publicEnv.ENV,
    // Correlate the browser trace with the BFF (same-origin); the BFF injects traceparent onward.
    distributedTracingOrigins: [window.location.origin],
    propagateTracestate: true,
  });
}

/** Attach user/session context after login. No PII beyond the user id. */
export async function setRumUser(user: { id: string; role?: string; locale?: string }): Promise<void> {
  if (typeof window === "undefined" || !publicEnv.RUM_SERVER_URL) return;
  const { apm } = await import("@elastic/apm-rum");
  apm.setUserContext({ id: user.id });
  apm.addLabels({ role: user.role ?? "", locale: user.locale ?? "" });
}

/** Clear user/session context on logout. */
export async function clearRumUser(): Promise<void> {
  if (typeof window === "undefined" || !publicEnv.RUM_SERVER_URL) return;
  const { apm } = await import("@elastic/apm-rum");
  apm.setUserContext({});
  apm.addLabels({ role: "", locale: "" });
}
