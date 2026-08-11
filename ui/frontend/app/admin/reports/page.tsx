"use client";
import { useQuery } from "@tanstack/react-query";
import { getPaymentMix, getPayoutsHistory, getPlatformKpis } from "@/lib/services/admin";
import { RecordTable } from "@/components/record-table";
import { formatBDT } from "@/lib/format";

export default function AdminReports() {
  const kpis = useQuery({ queryKey: ["platform-kpis"], queryFn: getPlatformKpis });
  const mix = useQuery({ queryKey: ["payment-mix"], queryFn: getPaymentMix });
  const payouts = useQuery({ queryKey: ["payouts-history"], queryFn: getPayoutsHistory });
  const k = kpis.data;
  const byProvider = (mix.data?.by_provider ?? mix.data?.by_provider_count ?? {}) as Record<string, number>;
  const payoutRows = (payouts.data?.payouts ?? []) as Record<string, unknown>[];

  return (
    <div className="space-y-6">
      <h1 className="text-xl font-semibold">Reports</h1>
      <section>
        <h2 className="mb-2 font-medium">Platform KPIs</h2>
        {kpis.isLoading ? <div className="h-16 animate-pulse rounded bg-muted" /> : (
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4 text-sm">
            <div className="rounded-lg border border-border p-3"><div className="text-muted-foreground">GMV</div><div className="font-semibold">{formatBDT(k?.gmv_minor)}</div></div>
            <div className="rounded-lg border border-border p-3"><div className="text-muted-foreground">Orders</div><div className="font-semibold">{k?.orders ?? 0}</div></div>
            <div className="rounded-lg border border-border p-3"><div className="text-muted-foreground">AOV</div><div className="font-semibold">{formatBDT(k?.aov_minor)}</div></div>
            <div className="rounded-lg border border-border p-3"><div className="text-muted-foreground">Take rate</div><div className="font-semibold">{k?.take_rate_pct != null ? `${k.take_rate_pct}%` : "—"}</div></div>
          </div>
        )}
      </section>
      <section>
        <h2 className="mb-2 font-medium">Payment mix (GMV by provider)</h2>
        {Object.keys(byProvider).length === 0 ? <p className="text-sm text-muted-foreground">No data.</p> : (
          <ul className="divide-y divide-border rounded-lg border border-border text-sm">
            {Object.entries(byProvider).map(([p, v]) => <li key={p} className="flex justify-between p-3"><span className="capitalize">{p}</span><span>{typeof v === "number" && v > 1000 ? formatBDT(v) : String(v)}</span></li>)}
          </ul>
        )}
      </section>
      <section>
        <h2 className="mb-2 font-medium">Payouts history</h2>
        {payouts.isLoading ? <div className="h-20 animate-pulse rounded bg-muted" /> : <RecordTable rows={payoutRows} />}
      </section>
      <section>
        <h2 className="mb-2 font-medium">Regulatory exports</h2>
        <p className="text-sm text-muted-foreground">NBR-VAT and BTRC-DBID exports are available server-side (GET /reporting/exports/*) — downloaded via the BFF with admin auth; not embedded here.</p>
      </section>
    </div>
  );
}
