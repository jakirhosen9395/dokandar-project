import { SiteHeader } from "@/components/site-header";
import { SearchResults } from "@/features/search/search-results";
import { publicGet } from "@/lib/api-server";
import type { Category, SearchResponse } from "@/types/marketplace";

export const dynamic = "force-dynamic";

type SP = Record<string, string | undefined>;

export default async function SearchPage({ searchParams }: { searchParams: Promise<SP> }) {
  const sp = await searchParams;
  const q = sp.q ?? "";
  const cid = sp.cid ?? sp.category_id ?? "";

  // GAP-2: over-fetch a window (backend caps page size at 100) so client-side facets have data to filter.
  const qs = new URLSearchParams({ size: "100", page: "1" });
  if (q) qs.set("q", q);
  if (cid) qs.set("category_id", cid);

  const [results, catsResp] = await Promise.all([
    publicGet<SearchResponse>(`search/products?${qs.toString()}`),
    publicGet<{ tree: Category[] }>("catalog/categories/tree", { revalidate: 300 }),
  ]);
  const items = results?.items ?? [];
  const total = results?.total ?? items.length;
  const cats = catsResp?.tree ?? [];

  return (
    <>
      <SiteHeader />
      <main className="mx-auto max-w-7xl px-4 py-6">
        <h1 className="mb-4 text-lg font-semibold">{q ? `Results for “${q}”` : "All products"}</h1>
        <SearchResults items={items} cats={cats} total={total} activeCid={cid} q={q} />
      </main>
    </>
  );
}
