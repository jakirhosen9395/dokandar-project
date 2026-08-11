"use client";
import { use } from "react";
import { useQuery } from "@tanstack/react-query";
import { lookupProfile, lookupWallet } from "@/lib/services/admin";
import { formatBDT } from "@/lib/format";

export default function AdminUserDetail({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params);
  const profile = useQuery({ queryKey: ["admin-profile", id], queryFn: () => lookupProfile(id) });
  const wallet = useQuery({ queryKey: ["admin-wallet", id], queryFn: () => lookupWallet(id) });
  const p = profile.data;
  const w = wallet.data;

  return (
    <div className="space-y-4">
      <h1 className="text-xl font-semibold">User {id.slice(0, 12)}</h1>
      <section className="rounded-lg border border-border p-4 text-sm">
        <h2 className="mb-2 font-medium">Profile</h2>
        {profile.isLoading ? (
          <div className="h-12 animate-pulse rounded bg-muted" />
        ) : !p || p.error ? (
          <p className="text-muted-foreground">Profile not found or not accessible (ensure the user id is a valid uuid).</p>
        ) : (
          <pre className="overflow-x-auto whitespace-pre-wrap text-xs text-muted-foreground">{JSON.stringify(p, null, 2).slice(0, 800)}</pre>
        )}
      </section>
      <section className="rounded-lg border border-border p-4 text-sm">
        <h2 className="mb-2 font-medium">Wallet</h2>
        {wallet.isLoading ? (
          <div className="h-8 animate-pulse rounded bg-muted" />
        ) : !w || w.error ? (
          <p className="text-muted-foreground">Wallet not accessible (admin balance lookup may be scope-restricted).</p>
        ) : (
          <div>Balance: <span className="font-semibold">{formatBDT((w.balance_minor ?? w.available_minor) as number)}</span></div>
        )}
      </section>
    </div>
  );
}
