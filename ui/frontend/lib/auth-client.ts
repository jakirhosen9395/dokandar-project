"use client";
/**
 * Client auth controller. Talks ONLY to the BFF (same-origin); never to the gateway directly.
 * Access token lives in the Zustand store (memory). Refresh is single-flight (in-tab) + multi-tab
 * synchronized via BroadcastChannel. No localStorage/sessionStorage.
 */
import { useAuthStore } from "@/stores/auth";
import type { ClientSession } from "@/lib/auth";

const CHANNEL_NAME = "dokandar-auth";
export type AuthBroadcast = { type: "auth"; access_token: string; expires_in: number } | { type: "logout" };

let _bc: BroadcastChannel | null = null;
function bc(): BroadcastChannel | null {
  if (typeof window === "undefined" || !("BroadcastChannel" in window)) return null;
  return (_bc ??= new BroadcastChannel(CHANNEL_NAME));
}
function broadcast(msg: AuthBroadcast) {
  bc()?.postMessage(msg);
}
export function onAuthBroadcast(handler: (msg: AuthBroadcast) => void): () => void {
  const ch = bc();
  if (!ch) return () => {};
  const fn = (e: MessageEvent) => handler(e.data as AuthBroadcast);
  ch.addEventListener("message", fn);
  return () => ch.removeEventListener("message", fn);
}

const post = (url: string, body?: unknown): Promise<Response> =>
  fetch(url, {
    method: "POST",
    credentials: "same-origin",
    headers: body ? { "content-type": "application/json" } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });

export async function requestOtp(phone: string, mode: "login" | "signup"): Promise<boolean> {
  return (await post(`/api/gw/auth/${mode}/request`, { phone })).ok; // 202
}

export async function verifyOtp(input: {
  mode: "login" | "signup";
  phone: string;
  code: string;
  name?: string;
  lang?: string;
  email?: string;
}): Promise<ClientSession | null> {
  const r = await post("/api/auth/verify", input);
  if (!r.ok) {
    useAuthStore.getState().setStatus("error", "verification failed");
    return null;
  }
  const s = (await r.json()) as ClientSession;
  useAuthStore.getState().setToken(s.access_token, s.expires_in);
  broadcast({ type: "auth", access_token: s.access_token, expires_in: s.expires_in });
  return s;
}

let refreshInFlight: Promise<ClientSession | null> | null = null;
export function refreshAccess(): Promise<ClientSession | null> {
  if (refreshInFlight) return refreshInFlight; // single-flight per tab
  refreshInFlight = (async () => {
    try {
      const r = await post("/api/auth/refresh");
      if (!r.ok) {
        useAuthStore.getState().clear();
        broadcast({ type: "logout" });
        return null;
      }
      const s = (await r.json()) as ClientSession;
      useAuthStore.getState().setToken(s.access_token, s.expires_in);
      broadcast({ type: "auth", access_token: s.access_token, expires_in: s.expires_in });
      return s;
    } finally {
      refreshInFlight = null;
    }
  })();
  return refreshInFlight;
}

export async function bootstrapSession(): Promise<ClientSession | null> {
  useAuthStore.getState().setStatus("loading");
  const r = await fetch("/api/auth/session", { credentials: "same-origin" });
  if (!r.ok) {
    useAuthStore.getState().setStatus("idle");
    return null;
  }
  const s = (await r.json()) as ClientSession;
  useAuthStore.getState().setToken(s.access_token, s.expires_in);
  return s;
}

export async function logout(): Promise<void> {
  await post("/api/auth/logout").catch(() => {});
  useAuthStore.getState().clear();
  broadcast({ type: "logout" });
}

/** Authed call through the BFF: attach Bearer; on 401 refresh once and retry. */
export async function authedFetch(path: string, init: RequestInit = {}): Promise<Response> {
  const token = useAuthStore.getState().accessToken;
  const headers = new Headers(init.headers);
  if (token) headers.set("authorization", `Bearer ${token}`);
  let r = await fetch(`/api/gw/${path}`, { ...init, headers, credentials: "same-origin" });
  if (r.status === 401) {
    const s = await refreshAccess();
    if (s) {
      headers.set("authorization", `Bearer ${s.access_token}`);
      r = await fetch(`/api/gw/${path}`, { ...init, headers, credentials: "same-origin" });
    }
  }
  return r;
}
