"use client";
import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { getInbox, getNotifPrefs, markAllRead, markRead, updateNotifPrefs } from "@/lib/services/account";

// GAP-9: the realtime inbox is NATS (not in the REST OpenAPI), so we POLL (30s) and add a manual refresh
// + last-synced timestamp + a notification-preferences editor (the prefs endpoint IS reachable).
export default function NotificationsPage() {
  const qc = useQueryClient();
  const [page, setPage] = useState(1);
  const inbox = useQuery({ queryKey: ["inbox", page], queryFn: () => getInbox(page, 20), refetchInterval: 30_000 });
  const invalidate = () => qc.invalidateQueries({ queryKey: ["inbox"] });
  const readOne = useMutation({ mutationFn: (id: string) => markRead(id), onSuccess: invalidate });
  const readAll = useMutation({ mutationFn: markAllRead, onSuccess: invalidate });

  const prefs = useQuery({ queryKey: ["notif-prefs"], queryFn: getNotifPrefs });
  const savePref = useMutation({
    mutationFn: (next: Record<string, unknown>) => updateNotifPrefs(next),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["notif-prefs"] }),
  });

  const items = inbox.data?.items ?? [];
  const total = inbox.data?.total ?? 0;
  const unread = items.filter((n) => !n.read && !n.read_at).length;
  const lastSynced = inbox.dataUpdatedAt ? new Date(inbox.dataUpdatedAt).toLocaleTimeString() : "—";
  const prefEntries = Object.entries((prefs.data ?? {}) as Record<string, unknown>).filter(([, v]) => typeof v === "boolean");

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h1 className="text-xl font-semibold">
          Notifications {unread > 0 && <span className="ml-1 rounded-full bg-red-500 px-2 py-0.5 text-xs text-white">{unread}</span>}
        </h1>
        <div className="flex items-center gap-3 text-sm">
          <span className="text-xs text-muted-foreground">synced {lastSynced}</span>
          <button onClick={() => invalidate()} disabled={inbox.isFetching} className="rounded border border-border px-2 py-1 hover:bg-muted disabled:opacity-50">{inbox.isFetching ? "↻" : "Refresh"}</button>
          {unread > 0 && <button onClick={() => readAll.mutate()} className="text-muted-foreground hover:underline">Mark all read</button>}
        </div>
      </div>

      {inbox.isLoading ? (
        <div className="h-24 animate-pulse rounded bg-muted" />
      ) : items.length === 0 ? (
        <p className="py-6 text-center text-muted-foreground">No notifications.</p>
      ) : (
        <ul className="divide-y divide-border rounded-lg border border-border">
          {items.map((n) => {
            const read = n.read || n.read_at;
            return (
              <li key={n.id} className={`flex items-start gap-3 p-3 text-sm ${read ? "" : "bg-muted/40"}`}>
                {!read && <span aria-hidden className="mt-1.5 h-2 w-2 shrink-0 rounded-full bg-blue-500" />}
                <div className="flex-1">
                  <div className="font-medium">{n.title ?? "Notification"}</div>
                  {n.body && <div className="text-muted-foreground">{n.body}</div>}
                  {n.created_at && <div className="text-xs text-muted-foreground">{n.created_at}</div>}
                </div>
                {!read && <button onClick={() => readOne.mutate(n.id)} className="text-xs text-muted-foreground hover:underline">Mark read</button>}
              </li>
            );
          })}
        </ul>
      )}
      {total > 20 && (
        <div className="flex justify-center gap-3 text-sm">
          <button disabled={page <= 1} onClick={() => setPage((p) => p - 1)} className="rounded border border-border px-3 py-1.5 disabled:opacity-40">← Prev</button>
          <span className="text-muted-foreground">Page {page}</span>
          <button disabled={page * 20 >= total} onClick={() => setPage((p) => p + 1)} className="rounded border border-border px-3 py-1.5 disabled:opacity-40">Next →</button>
        </div>
      )}

      <section className="rounded-lg border border-border p-4">
        <h2 className="mb-2 font-medium">Notification preferences</h2>
        {prefs.isLoading ? (
          <div className="h-10 animate-pulse rounded bg-muted" />
        ) : prefEntries.length === 0 ? (
          <p className="text-sm text-muted-foreground">No editable channel preferences returned.</p>
        ) : (
          <ul className="space-y-2 text-sm">
            {prefEntries.map(([k, v]) => (
              <li key={k} className="flex items-center justify-between">
                <span className="capitalize">{k.replace(/_/g, " ")}</span>
                <input
                  type="checkbox"
                  checked={Boolean(v)}
                  onChange={(e) => savePref.mutate({ ...(prefs.data as Record<string, unknown>), [k]: e.target.checked })}
                  aria-label={`Toggle ${k}`}
                />
              </li>
            ))}
          </ul>
        )}
        {savePref.isError && <p className="mt-1 text-xs text-red-500">Could not save preference.</p>}
      </section>
    </div>
  );
}
