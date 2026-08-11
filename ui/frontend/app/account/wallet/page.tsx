"use client";
import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { getWallet, getWalletEntries, getCashbackRules, topupWallet, type WalletEntry, type CashbackRule } from "@/lib/services/account";
import { formatBDT } from "@/lib/format";

const QUICK_TK = [100, 500, 1000, 2000]; // Taka quick-select
const MAX_TK = 100000;

function fmtWhen(v?: string): string {
  if (!v) return "";
  const d = new Date(v);
  return isNaN(d.getTime()) ? String(v) : d.toLocaleString("en-BD", { dateStyle: "medium", timeStyle: "short" });
}

export default function WalletPage() {
  const qc = useQueryClient();
  const wallet = useQuery({ queryKey: ["wallet"], queryFn: getWallet });
  const entries = useQuery({ queryKey: ["wallet-entries"], queryFn: () => getWalletEntries(25) });
  const cashback = useQuery({ queryKey: ["wallet-cashback"], queryFn: getCashbackRules });
  const list = (entries.data ?? []) as WalletEntry[];

  const [amountTk, setAmountTk] = useState("");
  const [err, setErr] = useState<string | null>(null);
  const [ok, setOk] = useState(false);

  const topup = useMutation({
    mutationFn: (paisa: number) => topupWallet(paisa),
    onSuccess: () => {
      setOk(true);
      setErr(null);
      setAmountTk("");
      qc.invalidateQueries({ queryKey: ["wallet"] });
      qc.invalidateQueries({ queryKey: ["wallet-entries"] });
      setTimeout(() => setOk(false), 3000);
    },
    onError: (e) => setErr(e instanceof Error ? e.message : "Top-up failed. Please try again."),
  });

  function submit(tk: number) {
    setOk(false);
    if (!Number.isFinite(tk) || tk < 1) {
      setErr("Enter an amount of at least ৳1.");
      return;
    }
    if (tk > MAX_TK) {
      setErr(`Maximum top-up is ${formatBDT(MAX_TK * 100)}.`);
      return;
    }
    setErr(null);
    topup.mutate(Math.round(tk * 100));
  }

  return (
    <div className="space-y-5">
      <h1 className="text-xl font-semibold">Wallet</h1>

      {/* Balance */}
      <div className="rounded-lg border border-border p-5">
        <div className="text-sm text-muted-foreground">Available balance</div>
        <div className="mt-1 text-3xl font-bold">
          {wallet.isLoading ? "…" : wallet.isError ? "—" : formatBDT(wallet.data?.available_minor ?? wallet.data?.balance_minor ?? 0)}
        </div>
        {wallet.isError ? <p className="mt-2 text-xs text-red-600">Couldn&apos;t load your balance. <button onClick={() => wallet.refetch()} className="underline">Retry</button></p> : null}
      </div>

      {/* Top-up */}
      <section className="rounded-lg border border-border p-5">
        <h2 className="mb-3 font-medium">Add money</h2>
        <div className="mb-3 flex flex-wrap gap-2">
          {QUICK_TK.map((tk) => (
            <button
              key={tk}
              type="button"
              disabled={topup.isPending}
              onClick={() => submit(tk)}
              className="rounded-md border border-border px-3 py-1.5 text-sm hover:bg-muted disabled:opacity-50"
            >
              +{formatBDT(tk * 100)}
            </button>
          ))}
        </div>
        <form
          className="flex items-center gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            submit(Number(amountTk));
          }}
        >
          <div className="relative">
            <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-muted-foreground">৳</span>
            <input
              type="number"
              inputMode="numeric"
              min={1}
              max={MAX_TK}
              step={1}
              value={amountTk}
              onChange={(e) => setAmountTk(e.target.value)}
              placeholder="Amount"
              className="w-36 rounded-md border border-border py-1.5 pl-7 pr-3 text-sm"
            />
          </div>
          <button
            type="submit"
            disabled={topup.isPending}
            className="rounded-md bg-foreground px-4 py-1.5 text-sm font-medium text-background hover:opacity-90 disabled:opacity-50"
          >
            {topup.isPending ? "Adding…" : "Add money"}
          </button>
        </form>
        {err ? <p className="mt-2 text-sm text-red-600">{err}</p> : null}
        {ok ? <p className="mt-2 text-sm text-green-600">Money added to your wallet.</p> : null}
      </section>

      {/* Cashback rules */}
      {(cashback.data?.length ?? 0) > 0 ? (
        <section className="rounded-lg border border-border p-5">
          <h2 className="mb-2 font-medium">Earn cashback</h2>
          <ul className="space-y-1 text-sm text-muted-foreground">
            {(cashback.data as CashbackRule[]).map((r, i) => (
              <li key={String(r.id ?? i)}>
                {r.reward_kind === "percent_back" && r.reward_value != null ? `${r.reward_value}% back` : "Cashback"}
                {r.min_subtotal_minor ? ` on orders over ${formatBDT(r.min_subtotal_minor)}` : ""}
                {r.reward_cap_minor ? `, up to ${formatBDT(r.reward_cap_minor)}` : ""}
                {r.max_per_user ? ` (max ${r.max_per_user}×)` : ""}
                .
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      {/* Transactions */}
      <section>
        <h2 className="mb-2 font-medium">Transactions</h2>
        {entries.isLoading ? (
          <div className="h-24 animate-pulse rounded bg-muted" />
        ) : entries.isError ? (
          <p className="text-sm text-red-600">
            Couldn&apos;t load transactions. <button onClick={() => entries.refetch()} className="underline">Retry</button>
          </p>
        ) : list.length === 0 ? (
          <p className="text-sm text-muted-foreground">No transactions yet.</p>
        ) : (
          <ul className="divide-y divide-border rounded-lg border border-border text-sm">
            {list.map((e, i) => {
              const credit = Number(e.credit_minor ?? 0);
              const debit = Number(e.debit_minor ?? 0);
              const net = credit - debit;
              const isCredit = net >= 0;
              return (
                <li key={String(e.id ?? i)} className="flex items-center justify-between p-3">
                  <div>
                    <div className="capitalize">{String(e.kind ?? "entry").replace(/_/g, " ")}</div>
                    {e.posted_at ? <div className="text-xs text-muted-foreground">{fmtWhen(e.posted_at)}</div> : null}
                  </div>
                  <span className={isCredit ? "text-green-600" : "text-red-600"}>
                    {isCredit ? "+" : "−"}
                    {formatBDT(Math.abs(net))}
                  </span>
                </li>
              );
            })}
          </ul>
        )}
      </section>
    </div>
  );
}
