"use client";
import Link from "next/link";
import { useUiStore } from "@/stores/ui";
import { ProductImage } from "@/components/product-image";
import { discountPct, formatBDT, pickLocale } from "@/lib/format";
import type { SearchItem } from "@/types/marketplace";

// GAP-5: no image refs in the payload → branded ProductImage placeholder. The card carries shop_id in
// the link (?shop=) so the product page's add-to-cart has it (mitigates GAP-6).
export function ProductCard({ item }: { item: SearchItem }) {
  const locale = useUiStore((s) => s.locale);
  const name = pickLocale(item.name_en, item.name_bn, locale);
  const price = item.sale_price_minor ?? item.list_price_minor;
  const off = discountPct(item.list_price_minor, item.sale_price_minor);
  const href = item.shop_id ? `/product/${item.product_id}?shop=${item.shop_id}` : `/product/${item.product_id}`;
  return (
    <Link
      href={href}
      className="group flex flex-col rounded-lg border border-border bg-card p-3 transition hover:shadow-md focus:outline-none focus-visible:ring-2 focus-visible:ring-ring"
    >
      <ProductImage id={item.product_id} name={name} className="mb-3 aspect-square w-full rounded-md" />
      <h3 className="line-clamp-2 text-sm font-medium group-hover:underline">{name}</h3>
      <div className="mt-1 flex items-baseline gap-2">
        <span className="font-semibold">{formatBDT(price, locale)}</span>
        {off != null && (
          <>
            <span className="text-xs text-muted-foreground line-through">{formatBDT(item.list_price_minor, locale)}</span>
            <span className="text-xs font-medium text-green-600">-{off}%</span>
          </>
        )}
      </div>
      <div className="mt-1 flex items-center gap-1 text-xs text-muted-foreground">
        {item.rating_avg != null ? (
          <span aria-label={`Rated ${item.rating_avg} of 5`}>★ {item.rating_avg.toFixed(1)} ({item.rating_count ?? 0})</span>
        ) : (
          <span>No ratings</span>
        )}
        {item.in_stock === false && <span className="ml-auto text-red-500">Out of stock</span>}
      </div>
    </Link>
  );
}
