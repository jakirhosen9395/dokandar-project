/**
 * Node-only session cookie helpers (Route Handlers). The httpOnly + (prod) Secure + SameSite=Lax cookie
 * carries the encrypted session (see session-core). The browser never sees the refresh token.
 */
import "server-only";
import { cookies } from "next/headers";
import { serverEnv } from "@/lib/env";
import {
  SESSION_COOKIE,
  SESSION_TTL_SECONDS,
  openSession,
  sealSession,
  type SessionPayload,
} from "@/lib/session-core";

export { SESSION_COOKIE };
export type { SessionPayload };

const cookieOpts = () => ({
  httpOnly: true,
  secure: serverEnv.APP_ENV !== "dev", // dev = http; prod = https
  sameSite: "lax" as const,
  path: "/",
  maxAge: SESSION_TTL_SECONDS,
});

export async function writeSessionCookie(p: SessionPayload): Promise<void> {
  (await cookies()).set(SESSION_COOKIE, await sealSession(p), cookieOpts());
}

export async function readSessionCookie(): Promise<SessionPayload | null> {
  const raw = (await cookies()).get(SESSION_COOKIE)?.value;
  return raw ? openSession(raw) : null;
}

export async function clearSessionCookie(): Promise<void> {
  (await cookies()).set(SESSION_COOKIE, "", { ...cookieOpts(), maxAge: 0 });
}
