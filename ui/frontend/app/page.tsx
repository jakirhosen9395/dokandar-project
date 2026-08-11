import Link from "next/link";
import { SiteHeader } from "@/components/site-header";
import { ProductGrid } from "@/components/product-grid";
import { publicGet } from "@/lib/api-server";
import type { Category, SearchItem, SearchResponse } from "@/types/marketplace";

export const dynamic = "force-dynamic";

async function getHome() {
  const [cats, trending, featured] = await Promise.all([
    publicGet<{ tree: Category[] }>("catalog/categories/tree", { revalidate: 300 }),
    publicGet<{ items: SearchItem[] }>("search/trending"),
    publicGet<SearchResponse>("search/products?size=10"),
  ]);
  return { cats: cats?.tree ?? [], trending: trending?.items ?? [], featured: featured?.items ?? [] };
}

export default async function HomePage() {
  const { cats, trending, featured } = await getHome();
  return (
    <>
      <SiteHeader />
      <main className="mx-auto max-w-7xl space-y-8 px-4 py-6">
        <section className="rounded-xl bg-gradient-to-r from-amber-100 to-orange-100 p-8 dark:from-amber-950 dark:to-orange-950">
          <h1 className="text-2xl font-bold sm:text-3xl">Welcome to DOKANDAR</h1>
          <p className="mt-1 text-muted-foreground">Bangladesh’s marketplace — discover thousands of products.</p>
          <Link href="/search" className="mt-4 inline-block rounded-md bg-foreground px-4 py-2 text-sm font-medium text-background">
            Start shopping
          </Link>
        </section>

        {cats.length > 0 && (
          <section>
            <h2 className="mb-3 text-lg font-semibold">Shop by category</h2>
            <div className="flex flex-wrap gap-2">
              {cats.slice(0, 12).map((c) => (
                <Link key={c.category_id} href={`/category/${c.slug ?? c.category_id}?cid=${c.category_id}`} className="rounded-full border border-border px-3 py-1.5 text-sm hover:bg-muted">
                  {c.name_en}
                </Link>
              ))}
            </div>
          </section>
        )}

        {trending.length > 0 && (
          <section>
            <h2 className="mb-3 text-lg font-semibold">Trending now</h2>
            <ProductGrid items={trending} />
          </section>
        )}

        {featured.length > 0 && (
          <section>
            <h2 className="mb-3 text-lg font-semibold">Featured products</h2>
            <ProductGrid items={featured} />
          </section>
        )}
      </main>
    </>
  );
}
