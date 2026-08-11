"use client";
import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { getOrdersByPeriod, lookupOrder } from "@/lib/services/admin";
import { RemediationCard } from "@/components/remediation-card";

function OrderLookup() {
  const [id, setId] = useState("");
  const [q, setQ] = useState("");
  const order = useQuery({ queryKey: ["admin-order", q], enabled: !!q, queryFn: () => lookupOrder(q), retry: false });
  const o = order.data;
  return (
    <section className="rounded-lg border border-border p-4">
      <h2 className="mb-2 font-medium">Look up an order by id</h2>
      <div className="flex gap-2">
        <input value={id} onChange={(e) => setId(e.target.value)} placeholder="order id (uuid)" aria-label="Order id" className="flex-1 rounded-md border border-border bg-background px-3 py-2 text-sm" />
        <button onClick={() => setQ(id)} className="rounded-md bg-foreground px-4 py-2 text-sm text-background">Look up</button>
      </div>
      <p className="mt-1 text-xs text-muted-foreground">A bulk order list isn’t available yet — inspect a specific order by its id.</p>
      {q && (order.isLoading ? (
        <div className="mt-3 h-10 animate-pulse rounded bg-muted" />
      ) : !o || o.error ? (
        <p className="mt-3 text-sm text-muted-foreground">Not found or not accessible for this id.</p>
      ) : (
        <pre className="mt-3 overflow-x-auto whitespace-pre-wrap rounded bg-muted/50 p-3 text-xs text-muted-foreground">{JSON.stringify(o, null, 2).slice(0, 800)}</pre>
      ))}
    </section>
  );
}

export default function AdminOrders() {
  const series = useQuery({ queryKey: ["orders-by-period"], queryFn: getOrdersByPeriod });
  const daily = series.data?.daily ?? [];
  const max = Math.max(1, ...daily.map((d) => d.orders ?? 0));

  return (
    <div className="space-y-5">
      <h1 className="text-xl font-semibold">Orders</h1>
      <OrderLookup />
      <section>
        <h2 className="mb-2 font-medium">Orders by day (aggregate, from reporting)</h2>
        {series.isLoading ? (
          <div className="h-32 animate-pulse rounded bg-muted" />
        ) : daily.length === 0 ? (
          <p className="text-sm text-muted-foreground">No data.</p>
        ) : (
          <div className="flex h-32 items-end gap-1 rounded-lg border border-border p-3" role="img" aria-label="Orders per day">
            {daily.slice(-30).map((d, i) => <div key={i} className="flex-1 rounded-t bg-foreground/70" style={{ height: `${Math.max(4, ((d.orders ?? 0) / max) * 100)}%` }} title={`${d.date}: ${d.orders ?? 0}`} />)}
          </div>
        )}
      </section>
      <RemediationCard
        title="Per-order monitoring unavailable"
        category="B"
        gap="GAP-13"
        why="A platform-wide order list isn’t available yet — orders can be inspected individually by id above, and aggregate volume is shown in the chart."
        owner="Backend — order service (admin order search API)"
        recommendedFix="Add a paginated admin order search (status / date / query) accessible to platform_staff and admin."
        stillWorks={["Aggregate order volume (chart above, from reporting)", "Payment & payout monitoring", "Platform KPIs"]}
      />
    </div>
  );
}
