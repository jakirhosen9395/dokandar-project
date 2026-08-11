import { ProductCard } from "@/components/product-card";
import type { SearchItem } from "@/types/marketplace";

export function ProductGrid({ items }: { items: SearchItem[] }) {
  if (!items.length) return <p className="py-10 text-center text-muted-foreground">No products found.</p>;
  return (
    <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5">
      {items.map((it) => (
        <ProductCard key={it.product_id} item={it} />
      ))}
    </div>
  );
}

export function ProductGridSkeleton({ count = 10 }: { count?: number }) {
  return (
    <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5" aria-hidden>
      {Array.from({ length: count }).map((_, i) => (
        <div key={i} className="flex flex-col rounded-lg border border-border p-3">
          <div className="mb-3 aspect-square w-full animate-pulse rounded-md bg-muted" />
          <div className="mb-2 h-4 w-3/4 animate-pulse rounded bg-muted" />
          <div className="h-4 w-1/3 animate-pulse rounded bg-muted" />
        </div>
      ))}
    </div>
  );
}
