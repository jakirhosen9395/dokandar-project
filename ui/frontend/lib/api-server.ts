/**
 * Server-side reads for SSR/RSC of PUBLIC marketplace data (catalog + search). Server Components fetch
 * the gateway directly (server-side, public endpoints — no token), injecting traceparent + x-request-id
 * for trace correlation. The gateway URL stays server-only; the browser never sees it.
 * Authed/interactive data (cart, reviews, recs) goes through the BFF + Bearer on the client.
 */
import "server-only";
import { randomBytes } from "node:crypto";
import { serverEnv } from "@/lib/env";

const hex = (n: number) => randomBytes(n).toString("hex");

export async function publicGet<T = unknown>(path: string, opts: { revalidate?: number } = {}): Promise<T | null> {
  try {
    const res = await fetch(`${serverEnv.GATEWAY_URL}/api/v1/${path}`, {
      headers: { "x-request-id": hex(16), traceparent: `00-${hex(16)}-${hex(8)}-01` },
      next: opts.revalidate != null ? { revalidate: opts.revalidate } : undefined,
      cache: opts.revalidate != null ? undefined : "no-store",
      signal: AbortSignal.timeout(6000),
    });
    if (!res.ok) return null;
    return (await res.json()) as T;
  } catch {
    return null;
  }
}
