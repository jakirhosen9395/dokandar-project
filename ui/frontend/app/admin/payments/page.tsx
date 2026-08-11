"use client";
import { useQuery } from "@tanstack/react-query";
import { getCodLedger, getCommissionRates, getPayouts } from "@/lib/services/admin";
import { RecordTable } from "@/components/record-table";

function Section({ title, q }: { title: string; q: ReturnType<typeof useQuery<unknown[] | null>> }) {
  const rows = (q.data ?? []) as Record<string, unknown>[];
  return (
    <section>
      <h2 className="mb-2 font-medium">{title} <span className="text-sm font-normal text-muted-foreground">({rows.length})</span></h2>
      {q.isLoading ? <div className="h-20 animate-pulse rounded bg-muted" /> : <RecordTable rows={rows} />}
    </section>
  );
}

export default function AdminPayments() {
  const payouts = useQuery({ queryKey: ["payouts"], queryFn: getPayouts });
  const rates = useQuery({ queryKey: ["commission-rates"], queryFn: getCommissionRates });
  const cod = useQuery({ queryKey: ["cod-ledger"], queryFn: getCodLedger });
  return (
    <div className="space-y-6">
      <h1 className="text-xl font-semibold">Payments</h1>
      <Section title="Payouts" q={payouts} />
      <Section title="Commission rates" q={rates} />
      <Section title="COD ledger" q={cod} />
      <p className="text-xs text-muted-foreground">Read-only monitoring. Payout execution + refunds are privileged write flows (POST /payment/payouts, /refunds) wired but not triggered from this view.</p>
    </div>
  );
}
