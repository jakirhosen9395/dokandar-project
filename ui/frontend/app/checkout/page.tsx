"use client";
import { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useMutation, useQuery } from "@tanstack/react-query";
import { SiteHeader } from "@/components/site-header";
import { useAuth } from "@/hooks/use-auth";
import { createCheckoutPackage, placeOrder, type CheckoutQuote } from "@/lib/services/checkout";
import { formatBDT } from "@/lib/format";

const uuid = () => (typeof crypto !== "undefined" && crypto.randomUUID ? crypto.randomUUID() : `k-${Math.abs(Date.now())}`);

export default function CheckoutPage() {
  const { isAuthenticated } = useAuth();
  const router = useRouter();
  const [coupon, setCoupon] = useState("");
  const [appliedCoupon, setAppliedCoupon] = useState("");
  const [orderKey] = useState(uuid); // stable per checkout session → double-submit is idempotent

  const quote = useQuery({
    queryKey: ["checkout-package", appliedCoupon],
    enabled: isAuthenticated,
    retry: false,
    queryFn: () => createCheckoutPackage({ payment_method: "cod", ...(appliedCoupon ? { coupon_code: appliedCoupon } : {}) }),
  });

  const place = useMutation({
    mutationFn: () => placeOrder(orderKey, quote.data as CheckoutQuote, "cod"),
    onSuccess: (res) => { if (res?.orderId) router.push(`/account/orders/${res.orderId}`); },
  });

  if (!isAuthenticated)
    return (
      <>
        <SiteHeader />
        <main className="mx-auto max-w-2xl px-4 py-10 text-center">
          <p className="text-muted-foreground">Log in to check out. Your cart will be waiting.</p>
          <Link href="/login?next=/checkout" className="mt-4 inline-block rounded-md bg-foreground px-4 py-2 text-sm text-background">Log in</Link>
        </main>
      </>
    );

  const q = quote.data;
  const lines = (q?.sub_orders ?? []).flatMap((so) => so.items.map((it) => ({ ...it, shop_id: so.shop_id })));
  const empty = quote.isError || (quote.isSuccess && lines.length === 0);

  return (
    <>
      <SiteHeader />
      <main className="mx-auto max-w-2xl space-y-5 px-4 py-6">
        <h1 className="text-xl font-semibold">Checkout</h1>

        {empty ? (
          <div className="rounded-lg border border-border p-6 text-center">
            <p className="text-muted-foreground">Your cart is empty.</p>
            <Link href="/search" className="mt-3 inline-block rounded-md border border-border px-4 py-2 text-sm hover:bg-muted">Browse products</Link>
          </div>
        ) : (
          <>
            <section className="rounded-lg border border-border p-4">
              <h2 className="mb-2 font-medium">Order summary {q ? `· ${q.sub_orders.length} shop(s)` : ""}</h2>
              {quote.isLoading ? (
                <div className="h-16 animate-pulse rounded bg-muted" />
              ) : (
                <ul className="divide-y divide-border text-sm">
                  {lines.map((it, i) => (
                    <li key={i} className="flex justify-between py-2">
                      <span className="text-muted-foreground">{it.product_id.slice(0, 8)} × {it.quantity}</span>
                      <span>{formatBDT(it.line_total_minor ?? it.unit_price_minor * it.quantity)}</span>
                    </li>
                  ))}
                </ul>
              )}
              <div className="mt-2 flex justify-between border-t border-border pt-2 font-semibold">
                <span>Total</span><span>{formatBDT(q?.grand_total_minor)}</span>
              </div>
              {q?.risk?.decision ? <p className="mt-1 text-xs text-muted-foreground">Risk check: {String(q.risk.decision)}</p> : null}
            </section>

            <section className="rounded-lg border border-border p-4">
              <h2 className="mb-2 font-medium">Coupon</h2>
              <div className="flex gap-2">
                <input value={coupon} onChange={(e) => setCoupon(e.target.value.toUpperCase())} placeholder="Coupon code" aria-label="Coupon code" className="flex-1 rounded-md border border-border bg-background px-3 py-2 text-sm" />
                <button onClick={() => setAppliedCoupon(coupon)} className="rounded-md border border-border px-3 py-1.5 text-sm hover:bg-muted">Apply</button>
              </div>
              {appliedCoupon && <p className="mt-1 text-xs text-muted-foreground">{q?.coupon_applied ? `Applied: ${appliedCoupon}` : `“${appliedCoupon}” not applied`}</p>}
            </section>

            <section className="rounded-lg border border-border p-4">
              <h2 className="mb-2 font-medium">Payment</h2>
              <label className="flex items-center gap-2 text-sm"><input type="radio" name="pay" checked readOnly /> Cash on delivery (COD)</label>
              <label className="mt-1 flex items-center gap-2 text-sm text-muted-foreground"><input type="radio" name="pay" disabled /> Online payment — coming soon</label>
            </section>

            <section className="rounded-lg border border-border p-4 text-sm text-muted-foreground">
              Delivery address is collected by the courier for COD orders. Saved-address selection is coming soon.
            </section>

            {place.isError && <p className="text-sm text-red-500">Could not place the order. Please try again.</p>}
            <button
              onClick={() => place.mutate()}
              disabled={place.isPending || quote.isLoading || !q}
              className="w-full rounded-md bg-foreground px-4 py-3 font-medium text-background disabled:opacity-50"
            >
              {place.isPending ? "Placing order…" : `Place COD order · ${formatBDT(q?.grand_total_minor)}`}
            </button>
          </>
        )}
      </main>
    </>
  );
}
