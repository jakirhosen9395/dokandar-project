"use client";
import Link from "next/link";
import { useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useAuth } from "@/hooks/use-auth";
import { addToWishlist } from "@/lib/services/cart";

// Wishlist is authed (cart/wishlist/items). Guests are prompted to log in (no fake success).
export function WishlistButton({ productId, variantId }: { productId: string; variantId?: string }) {
  const { isAuthenticated } = useAuth();
  const qc = useQueryClient();
  const [added, setAdded] = useState(false);
  const add = useMutation({
    mutationFn: () => addToWishlist(productId, variantId),
    onSuccess: (ok) => { if (ok) { setAdded(true); qc.invalidateQueries({ queryKey: ["wishlist"] }); } },
  });

  if (!isAuthenticated) {
    return (
      <Link href={`/login?next=${encodeURIComponent(`/product/${productId}`)}`} className="block rounded-md border border-border px-4 py-2 text-center text-sm hover:bg-muted">
        ♥ Log in to save
      </Link>
    );
  }
  return (
    <button onClick={() => add.mutate()} disabled={add.isPending || added} className="w-full rounded-md border border-border px-4 py-2 text-sm hover:bg-muted disabled:opacity-60">
      {added ? "♥ Saved to wishlist" : add.isPending ? "Saving…" : "♥ Add to wishlist"}
    </button>
  );
}
