"use client";
import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { lookupWallet } from "@/lib/services/admin";
import { formatBDT } from "@/lib/format";

export default function AdminWallets() {
  const [uid, setUid] = useState("");
  const [q, setQ] = useState("");
  const wallet = useQuery({ queryKey: ["wallet-lookup", q], enabled: !!q, queryFn: () => lookupWallet(q) });
  const w = wallet.data;

  return (
    <div className="space-y-4">
      <h1 className="text-xl font-semibold">Wallets</h1>
      <div className="flex gap-2">
        <input value={uid} onChange={(e) => setUid(e.target.value)} placeholder="user id (uuid)" aria-label="User id" className="flex-1 rounded-md border border-border bg-background px-3 py-2 text-sm" />
        <button onClick={() => setQ(uid)} className="rounded-md bg-foreground px-4 py-2 text-sm text-background">Look up</button>
      </div>
      <p className="text-xs text-muted-foreground">Per-user wallet lookup (GET /wallet/balance/&#123;user_id&#125;). No wallet-list API — look up by user id.</p>
      {q && (wallet.isLoading ? (
        <div className="h-12 animate-pulse rounded bg-muted" />
      ) : !w || w.error ? (
        <p className="text-sm text-muted-foreground">Not accessible (verify the uuid; admin lookup may be scope-restricted).</p>
      ) : (
        <div className="rounded-lg border border-border p-4">
          <div className="text-sm text-muted-foreground">Balance for {q.slice(0, 12)}</div>
          <div className="text-2xl font-bold">{formatBDT((w.balance_minor ?? w.available_minor) as number)}</div>
        </div>
      ))}
    </div>
  );
}
