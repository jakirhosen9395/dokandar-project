import { SiteHeader } from "@/components/site-header";
import { ProductGrid } from "@/components/product-grid";
import { publicGet } from "@/lib/api-server";
import type { SearchResponse } from "@/types/marketplace";

export const dynamic = "force-dynamic";

export default async function CategoryPage({
  params,
  searchParams,
}: {
  params: Promise<{ slug: string }>;
  searchParams: Promise<Record<string, string | undefined>>;
}) {
  const { slug } = await params;
  const cid = (await searchParams).cid ?? "";
  const qs = new URLSearchParams({ size: "24" });
  if (cid) qs.set("category_id", cid);
  const res = await publicGet<SearchResponse>(`search/products?${qs.toString()}`);
  return (
    <>
      <SiteHeader />
      <main className="mx-auto max-w-7xl px-4 py-6">
        <h1 className="mb-4 text-xl font-semibold capitalize">{decodeURIComponent(slug).replace(/-/g, " ")}</h1>
        <ProductGrid items={res?.items ?? []} />
      </main>
    </>
  );
}
