import { notFound } from "next/navigation";
import { SiteHeader } from "@/components/site-header";
import { ProductImage } from "@/components/product-image";
import { AddToCart } from "@/features/product/add-to-cart";
import { WishlistButton } from "@/features/product/wishlist-button";
import { ProductExtras } from "@/features/product/product-extras";
import { publicGet } from "@/lib/api-server";
import { formatBDT } from "@/lib/format";
import type { Product } from "@/types/marketplace";

export const dynamic = "force-dynamic";

type SP = Record<string, string | undefined>;

export default async function ProductPage({
  params,
  searchParams,
}: {
  params: Promise<{ productId: string }>;
  searchParams: Promise<SP>;
}) {
  const { productId } = await params;
  const sp = await searchParams;
  const data = await publicGet<{ product?: Product } & Partial<Product>>(`catalog/products/${productId}`);
  const product = (data?.product ?? (data as Product | null)) as Product | null;
  if (!product?.id) notFound();

  const price = product.sale_price_minor ?? product.list_price_minor;
  const variantId = product.variants?.[0]?.id;

  return (
    <>
      <SiteHeader />
      <main className="mx-auto max-w-6xl px-4 py-6">
        <div className="grid gap-8 md:grid-cols-2">
          <ProductImage id={product.id} name={product.name_en} className="aspect-square w-full rounded-lg" textClass="text-6xl" />
          <div>
            <h1 className="text-xl font-semibold">{product.name_en}</h1>
            <p className="text-muted-foreground">{product.name_bn}</p>
            {product.brand && <p className="mt-1 text-sm text-muted-foreground">Brand: {product.brand}</p>}
            <div className="mt-3 text-2xl font-bold">{formatBDT(price)}</div>
            <p className="mt-1 text-sm">
              {product.status === "active" ? <span className="text-green-600">In stock</span> : <span className="text-muted-foreground">{product.status ?? "—"}</span>}
            </p>
            <div className="mt-4 max-w-xs space-y-2">
              <AddToCart productId={product.id} shopId={sp.shop} variantId={variantId} name={product.name_en} priceMinor={price ?? undefined} />
              <WishlistButton productId={product.id} variantId={variantId} />
            </div>
            {product.description_en && (
              <div className="mt-6">
                <h2 className="font-medium">Description</h2>
                <p className="mt-1 text-sm text-muted-foreground">{product.description_en}</p>
              </div>
            )}
          </div>
        </div>
        <ProductExtras productId={product.id} />
      </main>
    </>
  );
}
