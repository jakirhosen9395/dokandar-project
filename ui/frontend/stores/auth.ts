/**
 * Auth UI/credential state only (Zustand). Holds the in-memory access token + auth status.
 * The user PROFILE (server data) is NOT stored here — it lives in TanStack Query (queryKey ['me']).
 * Nothing is persisted (no localStorage/sessionStorage); the access token dies with the tab and is
 * restored from the httpOnly session cookie via the BFF on load.
 */
import { create } from "zustand";

export type AuthStatus = "idle" | "loading" | "authenticated" | "error";

interface AuthState {
  accessToken: string | null;
  expiresAt: number | null; // epoch ms
  status: AuthStatus;
  error: string | null;
  setToken: (accessToken: string, expiresInSec: number) => void;
  clear: () => void;
  setStatus: (status: AuthStatus, error?: string | null) => void;
}

export const useAuthStore = create<AuthState>((set) => ({
  accessToken: null,
  expiresAt: null,
  status: "idle",
  error: null,
  setToken: (accessToken, expiresInSec) =>
    set({ accessToken, expiresAt: Date.now() + expiresInSec * 1000, status: "authenticated", error: null }),
  clear: () => set({ accessToken: null, expiresAt: null, status: "idle", error: null }),
  setStatus: (status, error = null) => set({ status, error }),
}));
