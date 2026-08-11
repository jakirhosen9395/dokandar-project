"use client";
import Link from "next/link";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useAuthStore } from "@/stores/auth";
import { getWishlist, removeWishlist, type WishItem } from "@/lib/services/account";
import { addToCart } from "@/lib/services/cart";
import { SiteHeader } from "@/components/site-header";
import { ProductImage } from "@/components/product-image";

const lid = (w: WishItem) => w.line_id ?? w.lineId ?? "";

export default function WishlistPage() {
  const authed = !!useAuthStore((s) => s.accessToken);
  const qc = useQueryClient();
  const wl = useQuery({ queryKey: ["wishlist"], enabled: authed, queryFn: getWishlist });
  const items = (wl.data?.items ?? []) as WishItem[];

  const remove = useMutation({
    mutationFn: (id: string) => removeWishlist(id),
    onMutate: async (id) => {
      await qc.cancelQueries({ queryKey: ["wishlist"] });
      const prev = qc.getQueryData<{ items: WishItem[] }>(["wishlist"]);
      if (prev) qc.setQueryData(["wishlist"], { ...prev, items: prev.items.filter((w) => lid(w) !== id) });
      return { prev };
    },
    onError: (_e, _v, ctx) => ctx?.prev && qc.setQueryData(["wishlist"], ctx.prev),
    onSettled: () => qc.invalidateQueries({ queryKey: ["wishlist"] }),
  });

  const move = useMutation({
    mutationFn: async (w: WishItem) => {
      if (w.shop_id && w.variant_id) await addToCart({ shop_id: w.shop_id, product_id: w.product_id, variant_id: w.variant_id, quantity: 1 });
      await removeWishlist(lid(w));
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["wishlist"] });
      qc.invalidateQueries({ queryKey: ["cart"] });
    },
  });

  if (!authed)
    return (
      <>
        <SiteHeader />
        <main className="mx-auto max-w-3xl px-4 py-6">
          <h1 className="mb-4 text-xl font-semibold">Wishlist</h1>
          <p className="text-muted-foreground">Log in to see your wishlist. <Link href="/login?next=/wishlist" className="underline">Log in</Link></p>
        </main>
      </>
    );

  return (
    <>
      <SiteHeader />
      <main className="mx-auto max-w-3xl px-4 py-6">
        <h1 className="mb-4 text-xl font-semibold">Wishlist</h1>
        {wl.isLoading ? (
          <div className="h-24 animate-pulse rounded bg-muted" />
        ) : items.length === 0 ? (
          <p className="py-6 text-center text-muted-foreground">Your wishlist is empty. <Link href="/search" className="underline">Browse products</Link>.</p>
        ) : (
          <ul className="divide-y divide-border rounded-lg border border-border">
            {items.map((w) => {
              const id = lid(w);
              return (
                <li key={id || w.product_id} className="flex items-center gap-4 p-4 text-sm">
                  <ProductImage id={w.product_id} name={w.product_id} className="h-14 w-14 shrink-0 rounded" textClass="text-base" />
                  <Link href={`/product/${w.product_id}`} className="flex-1 font-medium hover:underline">{w.product_id.slice(0, 8)}</Link>
                  <button onClick={() => move.mutate(w)} disabled={!w.shop_id || !w.variant_id} className="rounded border border-border px-2 py-1 text-xs hover:bg-muted disabled:opacity-40">Move to cart</button>
                  <button onClick={() => remove.mutate(id)} className="text-xs text-red-500 hover:underline">Remove</button>
                </li>
              );
            })}
          </ul>
        )}
      </main>
    </>
  );
}
