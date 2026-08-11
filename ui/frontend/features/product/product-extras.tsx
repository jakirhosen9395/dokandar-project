"use client";
import { useQuery } from "@tanstack/react-query";
import { useAuthStore } from "@/stores/auth";
import { authedFetch } from "@/lib/auth-client";
import { ProductGrid } from "@/components/product-grid";
import type { SearchItem } from "@/types/marketplace";

// Reviews + recommendations are Bearer-gated (GAP-3) → only when logged in; otherwise a prompt.
export function ProductExtras({ productId }: { productId: string }) {
  const authed = !!useAuthStore((s) => s.accessToken);

  const reviews = useQuery({
    queryKey: ["review-agg", productId],
    enabled: authed,
    queryFn: async () => {
      const r = await authedFetch(`review/aggregate?target_kind=product&target_id=${productId}`);
      return r.ok ? r.json() : null;
    },
  });

  const similar = useQuery({
    queryKey: ["similar", productId],
    enabled: authed,
    queryFn: async () => {
      const r = await authedFetch(`recommendation/similar/${productId}?size=10`);
      return r.ok ? r.json() : null;
    },
  });

  if (!authed) {
    return <p className="mt-10 text-sm text-muted-foreground">Log in to see ratings, reviews, and recommendations.</p>;
  }

  const simItems = (similar.data?.items ?? []).filter((i: SearchItem) => i?.product_id) as SearchItem[];

  return (
    <div className="mt-10 space-y-8">
      <section>
        <h2 className="mb-2 text-lg font-semibold">Ratings &amp; reviews</h2>
        {reviews.data?.count ? (
          <p className="text-sm">★ {Number(reviews.data.avg ?? 0).toFixed(1)} · {reviews.data.count} review(s)</p>
        ) : (
          <p className="text-sm text-muted-foreground">No reviews yet.</p>
        )}
      </section>
      {simItems.length > 0 && (
        <section>
          <h2 className="mb-3 text-lg font-semibold">Similar products</h2>
          <ProductGrid items={simItems} />
        </section>
      )}
    </div>
  );
}
