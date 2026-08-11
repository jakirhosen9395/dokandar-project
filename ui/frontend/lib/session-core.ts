/**
 * Edge-safe session crypto (used by both the Node route handlers AND the Edge middleware).
 * Uses jose + Web Crypto only (no node:crypto, no next/headers), so it runs in the middleware runtime.
 * Payload is ENCRYPTED (JWE A256GCM) — the refresh token never leaves an httpOnly, encrypted cookie.
 */
import { EncryptJWT, jwtDecrypt } from "jose";
import { serverEnv } from "@/lib/env";
import type { Role } from "@/lib/auth";

export const SESSION_COOKIE = "dokandar_session";
export const SESSION_TTL_SECONDS = 30 * 24 * 60 * 60; // 30d — matches the backend refresh lifetime

export interface SessionPayload {
  sub: string;
  role: Role;
  kyc?: string;
  rt: string; // opaque backend refresh token (BFF-only)
}

let cachedKey: Uint8Array | null = null;
async function key(): Promise<Uint8Array> {
  if (cachedKey) return cachedKey;
  const data = new TextEncoder().encode(serverEnv.SESSION_COOKIE_SECRET || "dev-insecure");
  cachedKey = new Uint8Array(await crypto.subtle.digest("SHA-256", data));
  return cachedKey;
}

export async function sealSession(p: SessionPayload): Promise<string> {
  return new EncryptJWT({ role: p.role, kyc: p.kyc, rt: p.rt })
    .setProtectedHeader({ alg: "dir", enc: "A256GCM" })
    .setSubject(p.sub)
    .setIssuedAt()
    .setExpirationTime(`${SESSION_TTL_SECONDS}s`)
    .encrypt(await key());
}

export async function openSession(token: string): Promise<SessionPayload | null> {
  try {
    const { payload } = await jwtDecrypt(token, await key());
    if (!payload.sub || !payload.role || !payload.rt) return null;
    return {
      sub: payload.sub,
      role: payload.role as Role,
      kyc: payload.kyc as string | undefined,
      rt: payload.rt as string,
    };
  } catch {
    return null;
  }
}
