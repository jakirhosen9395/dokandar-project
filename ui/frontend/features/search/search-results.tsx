"use client";
import { useState } from "react";
import Link from "next/link";
import { ProductGrid } from "@/components/product-grid";
import type { Category, SearchItem } from "@/types/marketplace";

// GAP-2: the search API filters only by category server-side. We over-fetch (top N) and apply price /
// rating / in-stock facets CLIENT-side over that window — labeled honestly. Category is a server param
// (server-rendered <Link> → SSR refetch); NO useSearchParams here so the grid stays SSR'd.
export function SearchResults({ items, cats, total, activeCid, q }: { items: SearchItem[]; cats: Category[]; total: number; activeCid: string; q: string }) {
  const [minPrice, setMinPrice] = useState("");
  const [maxPrice, setMaxPrice] = useState("");
  const [minRating, setMinRating] = useState(0);
  const [inStock, setInStock] = useState(false);
  const [page, setPage] = useState(1);
  const SIZE = 20;

  const catHref = (cid: string) => {
    const p = new URLSearchParams();
    if (q) p.set("q", q);
    if (cid) p.set("cid", cid);
    const s = p.toString();
    return s ? `/search?${s}` : "/search";
  };

  const price = (i: SearchItem) => (i.sale_price_minor ?? i.list_price_minor ?? 0) / 100;
  const filtered = items.filter((i) => {
    if (minPrice && price(i) < Number(minPrice)) return false;
    if (maxPrice && price(i) > Number(maxPrice)) return false;
    if (minRating && (i.rating_avg ?? 0) < minRating) return false;
    if (inStock && i.in_stock === false) return false;
    return true;
  });
  const pageItems = filtered.slice((page - 1) * SIZE, page * SIZE);
  const facetsActive = minPrice || maxPrice || minRating || inStock;

  return (
    <div className="flex flex-col gap-6 md:flex-row">
      <aside className="shrink-0 space-y-4 text-sm md:w-56">
        <div>
          <h3 className="mb-2 font-medium">Category</h3>
          <ul className="space-y-1">
            <li><Link href={catHref("")} className={!activeCid ? "font-semibold" : "text-muted-foreground hover:underline"}>All</Link></li>
            {cats.slice(0, 15).map((c) => (
              <li key={c.category_id}><Link href={catHref(c.category_id)} className={`block hover:underline ${activeCid === c.category_id ? "font-semibold" : "text-muted-foreground"}`}>{c.name_en}</Link></li>
            ))}
          </ul>
        </div>
        <div>
          <h3 className="mb-2 font-medium">Price (৳)</h3>
          <div className="flex gap-2">
            <input value={minPrice} onChange={(e) => { setMinPrice(e.target.value); setPage(1); }} placeholder="min" aria-label="Min price" className="w-full rounded border border-border bg-background px-2 py-1" />
            <input value={maxPrice} onChange={(e) => { setMaxPrice(e.target.value); setPage(1); }} placeholder="max" aria-label="Max price" className="w-full rounded border border-border bg-background px-2 py-1" />
          </div>
        </div>
        <div>
          <h3 className="mb-2 font-medium">Min rating</h3>
          <div className="flex flex-wrap gap-1">
            {[0, 1, 2, 3, 4].map((r) => (
              <button key={r} onClick={() => { setMinRating(r); setPage(1); }} className={`rounded border px-2 py-0.5 text-xs ${minRating === r ? "border-foreground bg-muted" : "border-border"}`}>{r === 0 ? "All" : `${r}★+`}</button>
            ))}
          </div>
        </div>
        <label className="flex items-center gap-2"><input type="checkbox" checked={inStock} onChange={(e) => { setInStock(e.target.checked); setPage(1); }} /> In stock only</label>
        <p className="rounded-md border border-dashed border-border p-2 text-xs text-muted-foreground">Price, rating &amp; stock filter the top {items.length} results shown. Brand &amp; seller filters are coming soon.</p>
      </aside>
      <div className="flex-1">
        <p className="mb-2 text-sm text-muted-foreground">{facetsActive ? `${filtered.length} of top ${items.length} shown` : `${total} items`}</p>
        <ProductGrid items={pageItems} />
        {filtered.length > SIZE && (
          <nav className="mt-6 flex items-center justify-center gap-3 text-sm" aria-label="Pagination">
            <button disabled={page <= 1} onClick={() => setPage((p) => p - 1)} className="rounded border border-border px-3 py-1.5 disabled:opacity-40">← Prev</button>
            <span className="text-muted-foreground">Page {page}</span>
            <button disabled={page * SIZE >= filtered.length} onClick={() => setPage((p) => p + 1)} className="rounded border border-border px-3 py-1.5 disabled:opacity-40">Next →</button>
          </nav>
        )}
      </div>
    </div>
  );
}
