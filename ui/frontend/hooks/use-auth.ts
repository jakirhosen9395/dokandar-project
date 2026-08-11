"use client";
import { useQuery } from "@tanstack/react-query";
import { useAuthStore } from "@/stores/auth";
import { authedFetch } from "@/lib/auth-client";
import type { User } from "@/lib/auth";

/** Current user — SERVER state (TanStack Query), not duplicated in Zustand. */
export function useUser() {
  const accessToken = useAuthStore((s) => s.accessToken);
  return useQuery<User | null>({
    queryKey: ["me"],
    queryFn: async () => {
      const r = await authedFetch("auth/me");
      return r.ok ? ((await r.json()) as User) : null;
    },
    enabled: !!accessToken,
    staleTime: 5 * 60_000,
  });
}

/** Combined auth view: credential/UI state (Zustand) + user profile (Query). */
export function useAuth() {
  const status = useAuthStore((s) => s.status);
  const error = useAuthStore((s) => s.error);
  const accessToken = useAuthStore((s) => s.accessToken);
  const { data: user } = useUser();
  return {
    user: user ?? null,
    role: user?.role ?? null,
    status,
    error,
    isAuthenticated: !!accessToken && status === "authenticated",
  };
}
