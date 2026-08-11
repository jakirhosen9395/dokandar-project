"use client";
import Link from "next/link";
import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useAuth } from "@/hooks/use-auth";
import { getCatalogProducts, type CatProduct } from "@/lib/services/seller";
import { formatBDT } from "@/lib/format";

function StatusPill({ s }: { s?: string }) {
  const tone = s === "active" ? "bg-green-500/15 text-green-600" : s === "draft" ? "bg-amber-500/15 text-amber-600" : "bg-muted text-muted-foreground";
  return <span className={`rounded-full px-2 py-0.5 text-xs ${tone}`}>{s ?? "—"}</span>;
}

export default function SellerProducts() {
  const { user } = useAuth();
  const [q, setQ] = useState("");
  const [page, setPage] = useState(1);
  const SIZE = 20;
  const { data, isLoading } = useQuery({ queryKey: ["seller-products"], queryFn: () => getCatalogProducts(200) });
  const all = (data?.items ?? data?.products ?? []) as CatProduct[];
  const mine = (user?.id ? all.filter((p) => p.owner_id === user.id) : all).filter(
    (p) => !q || (p.name_en + p.name_bn + (p.sku ?? "")).toLowerCase().includes(q.toLowerCase()),
  );
  const pageItems = mine.slice((page - 1) * SIZE, page * SIZE);

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-semibold">Products</h1>
        <Link href="/seller/products/new" className="rounded-md bg-foreground px-3 py-1.5 text-sm font-medium text-background">+ New product</Link>
      </div>
      <input value={q} onChange={(e) => { setQ(e.target.value); setPage(1); }} placeholder="Search my products…" aria-label="Search products" className="w-full rounded-md border border-border bg-background px-3 py-2 text-sm" />
      <p className="text-xs text-muted-foreground">Showing your products. Draft visibility may vary.</p>
      {isLoading ? (
        <div className="space-y-2">{[0, 1, 2].map((i) => <div key={i} className="h-14 animate-pulse rounded bg-muted" />)}</div>
      ) : mine.length === 0 ? (
        <p className="py-8 text-center text-muted-foreground">No products yet. <Link href="/seller/products/new" className="underline">Create one</Link>.</p>
      ) : (
        <ul className="divide-y divide-border rounded-lg border border-border">
          {pageItems.map((p) => (
            <li key={p.id} className="flex items-center justify-between p-3 text-sm">
              <Link href={`/seller/products/${p.id}`} className="flex-1 hover:underline">
                <span className="font-medium">{p.name_en}</span> <span className="text-muted-foreground">· {p.sku ?? "no-sku"}</span>
              </Link>
              <div className="flex items-center gap-3">
                <span>{formatBDT(p.sale_price_minor ?? p.list_price_minor)}</span>
                <StatusPill s={p.status} />
              </div>
            </li>
          ))}
        </ul>
      )}
      {mine.length > SIZE && (
        <div className="flex justify-center gap-3 text-sm">
          <button disabled={page <= 1} onClick={() => setPage((p) => p - 1)} className="rounded border border-border px-3 py-1.5 disabled:opacity-40">← Prev</button>
          <span className="text-muted-foreground">Page {page}</span>
          <button disabled={page * SIZE >= mine.length} onClick={() => setPage((p) => p + 1)} className="rounded border border-border px-3 py-1.5 disabled:opacity-40">Next →</button>
        </div>
      )}
    </div>
  );
}
