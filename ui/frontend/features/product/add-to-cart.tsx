"use client";
import { useState } from "react";
import { useRouter } from "next/navigation";
import { useCart } from "@/hooks/use-cart";
import { useAuth } from "@/hooks/use-auth";
import { useGuestCart } from "@/stores/guest-cart";

// shop_id comes from the search/listing context (?shop=); variant_id from the product's first variant.
// Authed → server cart (cart/me). Guest → client-side cart (GAP-4), merged on login.
export function AddToCart({ productId, shopId, variantId, name, priceMinor }: { productId: string; shopId?: string; variantId?: string; name?: string; priceMinor?: number }) {
  const { isAuthenticated } = useAuth();
  const { add } = useCart();
  const guestAdd = useGuestCart((s) => s.add);
  const router = useRouter();
  const [added, setAdded] = useState(false);

  if (!shopId || !variantId) {
    return (
      <div className="rounded-md border border-dashed border-border p-2 text-xs text-muted-foreground">
        To add this item to your cart, open it from search or a product listing.
      </div>
    );
  }

  async function go(buyNow: boolean) {
    if (isAuthenticated) {
      try {
        await add.mutateAsync({ shop_id: shopId!, product_id: productId, variant_id: variantId!, quantity: 1 });
      } catch {
        return;
      }
    } else {
      guestAdd({ shop_id: shopId!, product_id: productId, variant_id: variantId!, quantity: 1, name, price_minor: priceMinor });
    }
    setAdded(true);
    if (buyNow) router.push("/cart");
  }

  return (
    <div className="space-y-2">
      <button onClick={() => go(false)} disabled={add.isPending} className="w-full rounded-md bg-foreground px-4 py-2 font-medium text-background disabled:opacity-50">
        {add.isPending ? "Adding…" : added ? "Added ✓ — add another" : "Add to cart"}
      </button>
      <button onClick={() => go(true)} disabled={add.isPending} className="w-full rounded-md border border-border px-4 py-2 font-medium hover:bg-muted disabled:opacity-50">
        Buy now
      </button>
      {!isAuthenticated && added && <p className="text-xs text-muted-foreground">Saved to your cart — it’ll move to your account when you log in.</p>}
      {add.isError && <p className="text-sm text-red-500">Could not add to cart. Please try again.</p>}
    </div>
  );
}
