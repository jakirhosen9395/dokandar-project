"use client";
import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createRiskRule, getRiskRules } from "@/lib/services/admin";
import { RecordTable } from "@/components/record-table";

export default function AdminRisk() {
  const qc = useQueryClient();
  const rules = useQuery({ queryKey: ["risk-rules"], queryFn: getRiskRules });
  const rows = (rules.data ?? []) as Record<string, unknown>[];
  const [raw, setRaw] = useState('{"name":"high_value_cod","kind":"threshold","enabled":true}');
  const create = useMutation({
    mutationFn: () => createRiskRule(JSON.parse(raw)),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["risk-rules"] }),
  });

  return (
    <div className="space-y-6">
      <h1 className="text-xl font-semibold">Risk &amp; trust</h1>
      <section>
        <h2 className="mb-2 font-medium">Rules <span className="text-sm font-normal text-muted-foreground">({rows.length})</span></h2>
        {rules.isLoading ? <div className="h-20 animate-pulse rounded bg-muted" /> : <RecordTable rows={rows} />}
      </section>
      <section className="rounded-lg border border-border p-4">
        <h2 className="mb-2 font-medium">Create rule</h2>
        <p className="mb-2 text-xs text-muted-foreground">Enter the rule as JSON — the server validates it on submit.</p>
        <textarea value={raw} onChange={(e) => setRaw(e.target.value)} rows={3} className="w-full rounded-md border border-border bg-background px-3 py-2 font-mono text-xs" />
        {create.isError && <p className="mt-1 text-sm text-red-500">Rejected (invalid JSON or backend validation).</p>}
        {create.isSuccess && <p className="mt-1 text-sm text-green-600">Rule created.</p>}
        <button onClick={() => { try { JSON.parse(raw); create.mutate(); } catch { /* invalid json */ } }} disabled={create.isPending} className="mt-2 rounded-md bg-foreground px-4 py-2 text-sm font-medium text-background disabled:opacity-50">
          {create.isPending ? "Creating…" : "Create rule"}
        </button>
      </section>
      <p className="text-xs text-muted-foreground">Overrides (POST /risk/admin/overrides) and live scoring (checkout/cod/review) are wired in the service layer; overrides are applied per-case from the order/risk context (not bulk-edited here).</p>
    </div>
  );
}
