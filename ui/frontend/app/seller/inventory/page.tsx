"use client";
import Link from "next/link";
import { useQuery } from "@tanstack/react-query";
import { useAuth } from "@/hooks/use-auth";
import { getCatalogProducts, type CatProduct } from "@/lib/services/seller";

export default function Inventory() {
  const { user } = useAuth();
  const { data, isLoading } = useQuery({ queryKey: ["seller-products"], queryFn: () => getCatalogProducts(200) });
  const all = (data?.items ?? data?.products ?? []) as CatProduct[];
  const mine = user?.id ? all.filter((p) => p.owner_id === user.id) : all;
  const rows = mine.flatMap((p) =>
    (p.variants ?? [{ id: p.id }]).map((v) => ({ pid: p.id, name: p.name_en, vid: v.id, sku: (v.sku as string) ?? p.sku, stock: Number(v.stock ?? v.quantity ?? 0) })),
  );

  return (
    <div className="space-y-4">
      <h1 className="text-xl font-semibold">Inventory</h1>
      <p className="text-xs text-muted-foreground">Set per-variant stock on each product’s page. Inventory history isn’t available yet.</p>
      {isLoading ? (
        <div className="h-24 animate-pulse rounded bg-muted" />
      ) : rows.length === 0 ? (
        <p className="py-8 text-center text-muted-foreground">No stock to show. <Link href="/seller/products/new" className="underline">Create products</Link> first.</p>
      ) : (
        <ul className="divide-y divide-border rounded-lg border border-border text-sm">
          {rows.map((r, i) => (
            <li key={r.vid + i} className="flex items-center justify-between p-3">
              <Link href={`/seller/products/${r.pid}`} className="hover:underline">
                {r.name} <span className="text-muted-foreground">· {String(r.sku ?? "").slice(0, 10)}</span>
              </Link>
              <span className={r.stock <= 5 ? "font-medium text-red-500" : ""}>{r.stock}{r.stock <= 5 ? " ⚠ low" : ""}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
