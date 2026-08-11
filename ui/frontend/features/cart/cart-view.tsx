"use client";
import Link from "next/link";
import { useCart } from "@/hooks/use-cart";
import { useAuth } from "@/hooks/use-auth";
import { useGuestCart } from "@/stores/guest-cart";
import { ProductImage } from "@/components/product-image";
import { formatBDT } from "@/lib/format";
import type { CartLine } from "@/types/marketplace";

const lid = (l: CartLine) => l.line_id ?? l.lineId ?? "";

export function CartView() {
  const { isAuthenticated } = useAuth();
  const { items, isLoading, update, remove, cart } = useCart();
  const guest = useGuestCart();

  // GAP-4: guests get a client-side cart (persisted), merged into the server cart on login.
  if (!isAuthenticated) {
    if (!guest.items.length)
      return (
        <div className="p-6 text-center">
          <p className="text-muted-foreground">Your cart is empty.</p>
          <Link href="/search" className="mt-4 inline-block rounded-md border border-border px-4 py-2 text-sm hover:bg-muted">Browse products</Link>
        </div>
      );
    const subtotal = guest.items.reduce((s, l) => s + (l.price_minor ?? 0) * l.quantity, 0);
    return (
      <div className="space-y-4">
        <ul className="divide-y divide-border rounded-lg border border-border">
          {guest.items.map((l) => (
            <li key={l.product_id + l.variant_id} className="flex items-center gap-4 p-4 text-sm">
              <ProductImage id={l.product_id} name={l.name} className="h-16 w-16 shrink-0 rounded" textClass="text-lg" />
              <div className="flex-1">
                <Link href={`/product/${l.product_id}?shop=${l.shop_id}`} className="font-medium hover:underline">{l.name ?? l.product_id.slice(0, 8)}</Link>
                {l.price_minor != null && <div className="text-muted-foreground">{formatBDT(l.price_minor)}</div>}
              </div>
              <div className="flex items-center gap-2">
                <button aria-label="Decrease quantity" onClick={() => guest.setQty(l.product_id, l.variant_id, l.quantity - 1)} className="rounded border border-border px-2">−</button>
                <span className="w-6 text-center tabular-nums">{l.quantity}</span>
                <button aria-label="Increase quantity" onClick={() => guest.setQty(l.product_id, l.variant_id, l.quantity + 1)} className="rounded border border-border px-2">+</button>
              </div>
              <button onClick={() => guest.remove(l.product_id, l.variant_id)} className="text-sm text-red-500 hover:underline">Remove</button>
            </li>
          ))}
        </ul>
        <div className="flex items-center justify-between rounded-lg border border-border p-4">
          <span className="text-sm text-muted-foreground">Subtotal</span>
          <span className="text-lg font-semibold">{formatBDT(subtotal)}</span>
        </div>
        <Link href="/login?next=/cart" className="block rounded-md bg-foreground px-4 py-2.5 text-center font-medium text-background">Log in to checkout</Link>
        <p className="text-center text-xs text-muted-foreground">Your items are saved and will move to your account when you log in.</p>
      </div>
    );
  }
  if (isLoading) return <p className="p-6 text-muted-foreground">Loading cart…</p>;
  if (!items.length)
    return (
      <div className="p-6 text-center">
        <p className="text-muted-foreground">Your cart is empty.</p>
        <Link href="/search" className="mt-4 inline-block rounded-md border border-border px-4 py-2 text-sm hover:bg-muted">Browse products</Link>
      </div>
    );

  const subtotal = cart?.subtotal_minor;
  return (
    <div className="space-y-4">
      <ul className="divide-y divide-border rounded-lg border border-border">
        {items.map((l) => {
          const id = lid(l);
          const unit = l.unit_price_minor as number | undefined;
          return (
            <li key={id || l.product_id} className="flex items-center gap-4 p-4">
              <ProductImage id={l.product_id} name={(l.name_en as string) ?? l.product_id} className="h-16 w-16 shrink-0 rounded" textClass="text-lg" />
              <div className="flex-1 text-sm">
                <Link href={`/product/${l.product_id}`} className="font-medium hover:underline">
                  {(l.name_en as string) ?? l.product_id.slice(0, 8)}
                </Link>
                {unit != null && <div className="text-muted-foreground">{formatBDT(unit)}</div>}
              </div>
              <div className="flex items-center gap-2">
                <button aria-label="Decrease quantity" onClick={() => update.mutate({ id, quantity: Math.max(1, l.quantity - 1) })} className="rounded border border-border px-2">−</button>
                <span className="w-6 text-center tabular-nums">{l.quantity}</span>
                <button aria-label="Increase quantity" onClick={() => update.mutate({ id, quantity: l.quantity + 1 })} className="rounded border border-border px-2">+</button>
              </div>
              <button onClick={() => remove.mutate(id)} className="text-sm text-red-500 hover:underline">Remove</button>
            </li>
          );
        })}
      </ul>
      <div className="flex items-center justify-between rounded-lg border border-border p-4">
        <span className="text-sm text-muted-foreground">Subtotal{subtotal == null && " (computed at checkout)"}</span>
        <span className="text-lg font-semibold">{subtotal != null ? formatBDT(subtotal) : "—"}</span>
      </div>
      <Link href="/checkout" className="block rounded-md bg-foreground px-4 py-2.5 text-center font-medium text-background">Proceed to checkout</Link>
    </div>
  );
}
