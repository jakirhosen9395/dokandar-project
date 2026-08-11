"use client";
import Link from "next/link";
import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { getOrders } from "@/lib/services/account";
import { formatBDT } from "@/lib/format";

const STATUSES = ["placed", "confirmed", "delivered", "cancelled", "refunded"];
function StatusBadge({ s }: { s: string }) {
  const tone =
    s === "delivered" ? "bg-green-500/15 text-green-600" :
    s === "cancelled" || s === "refunded" ? "bg-red-500/15 text-red-600" :
    s ? "bg-blue-500/15 text-blue-600" : "bg-muted text-muted-foreground";
  return <span className={`rounded-full px-2 py-0.5 text-xs ${tone}`}>{s || "—"}</span>;
}

// Filtering/pagination are client-side (GAP-7: order list has no backend filter/page params).
export default function OrdersPage() {
  const { data, isLoading } = useQuery({ queryKey: ["orders"], queryFn: getOrders });
  const [filter, setFilter] = useState("");
  const all = (data?.orders ?? []) as Record<string, unknown>[];
  const orders = filter ? all.filter((o) => (o.status ?? o.state) === filter) : all;

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-semibold">Your orders</h1>
        <select value={filter} onChange={(e) => setFilter(e.target.value)} aria-label="Filter by status" className="rounded border border-border bg-background px-2 py-1 text-sm">
          <option value="">All</option>
          {STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
        </select>
      </div>
      {isLoading ? (
        <div className="space-y-3">{[0, 1, 2].map((i) => <div key={i} className="h-16 animate-pulse rounded-lg bg-muted" />)}</div>
      ) : orders.length === 0 ? (
        <p className="py-8 text-center text-muted-foreground">No orders{filter ? ` with status “${filter}”` : " yet"}.</p>
      ) : (
        <ul className="space-y-3">
          {orders.map((o, i) => {
            const id = String(o.id ?? o.order_id ?? i);
            return (
              <li key={id}>
                <Link href={`/account/orders/${id}`} className="flex items-center justify-between rounded-lg border border-border p-4 hover:bg-muted">
                  <div>
                    <div className="font-medium">#{id.slice(0, 8)}</div>
                    {o.created_at ? <div className="text-xs text-muted-foreground">{String(o.created_at)}</div> : null}
                  </div>
                  <div className="flex items-center gap-3">
                    {o.grand_total_minor != null && <span className="text-sm">{formatBDT(o.grand_total_minor as number)}</span>}
                    <StatusBadge s={String(o.status ?? o.state ?? "")} />
                  </div>
                </Link>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
