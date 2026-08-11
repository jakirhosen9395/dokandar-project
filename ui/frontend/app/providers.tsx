"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { useAuthStore } from "@/stores/auth";
import { bootstrapSession, onAuthBroadcast, refreshAccess } from "@/lib/auth-client";
import { mergeGuestCart } from "@/lib/services/cart";
import { clearRumUser, initRum, setRumUser } from "@/lib/rum";

/** Client providers: TanStack Query + RUM + auth session lifecycle (bootstrap, silent refresh, multi-tab). */
export function Providers({ children }: { children: ReactNode }) {
  const [client] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            staleTime: 30_000,
            refetchOnWindowFocus: false,
            // Retry transient/network failures with backoff; never retry permanent 4xx (auth/validation).
            // networkMode "online" (default) pauses + resumes queries across offline transitions.
            retry: (count, err) => {
              const status = Number(String((err as Error)?.message).match(/→ (\d{3})/)?.[1]);
              if (status >= 400 && status < 500) return false;
              return count < 2;
            },
            retryDelay: (i) => Math.min(1000 * 2 ** i, 8000),
          },
          mutations: { retry: 0 },
        },
      }),
  );
  const expiresAt = useAuthStore((s) => s.expiresAt);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    void initRum();
  }, []);

  // Restore the session from the httpOnly cookie on load / new tab (access token back into memory).
  useEffect(() => {
    let active = true;
    void bootstrapSession().then((s) => {
      if (!active || !s) return;
      client.setQueryData(["me"], s.user);
      void setRumUser({ id: s.user.id, role: s.user.role, locale: s.user.lang });
      // GAP-4: replay any client-side guest cart into the server cart on session restore.
      void mergeGuestCart().then((merged) => {
        if (merged) void client.invalidateQueries({ queryKey: ["cart"] });
      });
    });
    return () => {
      active = false;
    };
  }, [client]);

  // Multi-tab synchronization via BroadcastChannel.
  useEffect(() => {
    return onAuthBroadcast((msg) => {
      if (msg.type === "auth") {
        useAuthStore.getState().setToken(msg.access_token, msg.expires_in);
        void client.invalidateQueries({ queryKey: ["me"] });
      } else {
        useAuthStore.getState().clear();
        client.setQueryData(["me"], null);
        void clearRumUser();
      }
    });
  }, [client]);

  // Silent refresh ~60s before the access token expires.
  useEffect(() => {
    if (timer.current) clearTimeout(timer.current);
    if (!expiresAt) return;
    const delay = Math.max(5_000, expiresAt - Date.now() - 60_000);
    timer.current = setTimeout(() => void refreshAccess(), delay);
    return () => {
      if (timer.current) clearTimeout(timer.current);
    };
  }, [expiresAt]);

  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}
