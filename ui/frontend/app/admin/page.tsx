"use client";
import Link from "next/link";
import { useQuery } from "@tanstack/react-query";
import { getOrdersByPeriod, getPaymentMix, getPlatformKpis } from "@/lib/services/admin";
import { formatBDT } from "@/lib/format";

function Kpi({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg border border-border p-4">
      <div className="text-sm text-muted-foreground">{label}</div>
      <div className="mt-1 text-2xl font-bold">{value}</div>
    </div>
  );
}

export default function AdminOverview() {
  const kpis = useQuery({ queryKey: ["platform-kpis"], queryFn: getPlatformKpis });
  const series = useQuery({ queryKey: ["orders-by-period"], queryFn: getOrdersByPeriod });
  const mix = useQuery({ queryKey: ["payment-mix"], queryFn: getPaymentMix });

  const k = kpis.data;
  const daily = series.data?.daily ?? [];
  const max = Math.max(1, ...daily.map((d) => d.orders ?? 0));
  const byProvider = (mix.data?.by_provider_count ?? mix.data?.by_provider ?? {}) as Record<string, number>;

  return (
    <div className="space-y-6">
      <h1 className="text-xl font-semibold">Platform overview</h1>
      {kpis.isLoading ? (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">{[0, 1, 2, 3].map((i) => <div key={i} className="h-20 animate-pulse rounded-lg bg-muted" />)}</div>
      ) : !k ? (
        <p className="text-sm text-muted-foreground">Platform KPIs unavailable.</p>
      ) : (
        <>
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
            <Kpi label="GMV" value={formatBDT(k.gmv_minor)} />
            <Kpi label="Orders" value={String(k.orders ?? 0)} />
            <Kpi label="AOV" value={formatBDT(k.aov_minor)} />
            <Kpi label="Take rate" value={k.take_rate_pct != null ? `${k.take_rate_pct}%` : "—"} />
          </div>
          {k.period_from && <p className="text-xs text-muted-foreground">Period: {k.period_from} → {k.period_to}</p>}
        </>
      )}

      <section>
        <h2 className="mb-2 font-medium">Orders by day</h2>
        {series.isLoading ? (
          <div className="h-32 animate-pulse rounded bg-muted" />
        ) : daily.length === 0 ? (
          <p className="text-sm text-muted-foreground">No order data for the period.</p>
        ) : (
          <div className="flex h-32 items-end gap-1 rounded-lg border border-border p-3" role="img" aria-label="Orders per day bar chart">
            {daily.slice(-30).map((d, i) => (
              <div key={i} className="flex-1 rounded-t bg-foreground/70" style={{ height: `${Math.max(4, ((d.orders ?? 0) / max) * 100)}%` }} title={`${d.date}: ${d.orders ?? 0}`} />
            ))}
          </div>
        )}
      </section>

      <section>
        <h2 className="mb-2 font-medium">Payment mix</h2>
        {mix.isLoading ? (
          <div className="h-16 animate-pulse rounded bg-muted" />
        ) : Object.keys(byProvider).length === 0 ? (
          <p className="text-sm text-muted-foreground">No payment data.</p>
        ) : (
          <ul className="divide-y divide-border rounded-lg border border-border text-sm">
            {Object.entries(byProvider).map(([p, v]) => (
              <li key={p} className="flex justify-between p-3"><span className="capitalize">{p}</span><span className="text-muted-foreground">{String(v)}</span></li>
            ))}
          </ul>
        )}
      </section>

      <div className="flex flex-wrap gap-2 text-sm">
        <Link href="/admin/reports" className="rounded border border-border px-3 py-1.5 hover:bg-muted">Full reports →</Link>
        <Link href="/admin/payments" className="rounded border border-border px-3 py-1.5 hover:bg-muted">Payments →</Link>
        <Link href="/admin/risk" className="rounded border border-border px-3 py-1.5 hover:bg-muted">Risk →</Link>
        <Link href="/admin/system" className="rounded border border-border px-3 py-1.5 hover:bg-muted">System health →</Link>
      </div>
    </div>
  );
}
