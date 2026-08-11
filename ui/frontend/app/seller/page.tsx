"use client";
import Link from "next/link";
import { useQuery } from "@tanstack/react-query";
import { useAuth } from "@/hooks/use-auth";
import { checkReachable, getCatalogProducts, getMyCoupons, type CatProduct, type Coupon } from "@/lib/services/seller";

function Stat({ title, value, href, muted }: { title: string; value: string; href?: string; muted?: boolean }) {
  const inner = (
    <div className={`rounded-lg border border-border p-4 ${href ? "hover:bg-muted" : ""}`}>
      <div className="text-sm text-muted-foreground">{title}</div>
      <div className={`mt-1 text-xl font-semibold ${muted ? "text-muted-foreground" : ""}`}>{value}</div>
    </div>
  );
  return href ? <Link href={href}>{inner}</Link> : inner;
}

function Diag({ label, status, gap }: { label: string; status?: number; gap?: string }) {
  const ok = status != null && status >= 200 && status < 300;
  const pending = status == null;
  return (
    <li className="flex items-center justify-between py-1.5 text-sm">
      <span>{label}</span>
      <span className={pending ? "text-muted-foreground" : ok ? "text-green-600" : "text-amber-600"} title={gap ? `ref ${gap}` : undefined}>
        {pending ? "checking…" : ok ? "✓ connected" : "✗ unavailable"}
      </span>
    </li>
  );
}

export default function SellerDashboard() {
  const { user } = useAuth();
  const products = useQuery({ queryKey: ["seller-products"], queryFn: () => getCatalogProducts(100) });
  const coupons = useQuery({ queryKey: ["seller-coupons"], queryFn: getMyCoupons });

  // live connection diagnostics — honest view of which seller dependencies are reachable right now
  const dCatalog = useQuery({ queryKey: ["diag", "catalog"], queryFn: () => checkReachable("catalog/products?limit=1") });
  const dCoupon = useQuery({ queryKey: ["diag", "coupon"], queryFn: () => checkReachable("coupon/coupons/me") });
  const dShop = useQuery({ queryKey: ["diag", "shop"], queryFn: () => checkReachable("shop/me") });
  const dMedia = useQuery({ queryKey: ["diag", "media"], queryFn: () => checkReachable("media") });

  const all = (products.data?.items ?? products.data?.products ?? []) as CatProduct[];
  const mine = user?.id ? all.filter((p) => p.owner_id === user.id) : all;
  const couponList = (Array.isArray(coupons.data) ? coupons.data : coupons.data?.items ?? []) as Coupon[];
  const lowStock = mine.filter((p) => (p.variants ?? []).some((v) => Number(v.stock ?? v.quantity ?? 0) <= 5)).length;

  const shopConnected = dShop.data != null && dShop.data >= 200 && dShop.data < 300;
  const hasProduct = mine.length > 0;
  const prereqs = [
    { label: "Shop connected", done: shopConnected, note: shopConnected ? "" : "shop setup not available yet" },
    { label: "At least one product created", done: hasProduct, note: hasProduct ? "" : "create a draft product" },
    { label: "Product media attached", done: false, note: "image upload not available yet" },
  ];

  return (
    <div className="space-y-6">
      <h1 className="text-xl font-semibold">Seller dashboard</h1>

      {/* shop status / onboarding */}
      <section className="rounded-lg border border-border p-4">
        <div className="flex items-center gap-2">
          <span aria-hidden className={`h-2.5 w-2.5 rounded-full ${shopConnected ? "bg-green-500" : "bg-amber-500"}`} />
          <h2 className="font-medium">Shop status: {dShop.isLoading ? "checking…" : shopConnected ? "Connected" : "Not connected"}</h2>
        </div>
        <p className="mt-2 text-sm text-muted-foreground">
          {shopConnected
            ? "Your shop is set up. Manage its profile and settings anytime."
            : "Set up your shop to publish products for sale."}
        </p>
        <Link href="/seller/shop" className="mt-3 inline-block rounded-md border border-border px-3 py-1.5 text-sm hover:bg-muted">
          {shopConnected ? "Manage shop" : "Set up shop"}
        </Link>
      </section>

      {/* stats */}
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        <Stat title="My products" value={products.isLoading ? "…" : String(mine.length)} href="/seller/products" />
        <Stat title="My coupons" value={coupons.isLoading ? "…" : String(couponList.length)} href="/seller/coupons" />
        <Stat title="Low-stock items" value={String(lowStock)} href="/seller/inventory" />
      </div>

      {/* publish prerequisites */}
      <section className="rounded-lg border border-border p-4">
        <h2 className="mb-2 font-medium">Publish prerequisites</h2>
        <ul className="space-y-1 text-sm">
          {prereqs.map((p) => (
            <li key={p.label} className="flex items-center gap-2">
              <span className={p.done ? "text-green-600" : "text-muted-foreground"}>{p.done ? "✓" : "○"}</span>
              <span>{p.label}</span>
              {p.note && <span className="text-xs text-muted-foreground">— {p.note}</span>}
            </li>
          ))}
        </ul>
        <button disabled className="mt-3 cursor-not-allowed rounded-md bg-muted px-4 py-2 text-sm font-medium text-muted-foreground">Publish shop (prerequisites not met)</button>
      </section>

      {/* connection diagnostics */}
      <section className="rounded-lg border border-border p-4">
        <h2 className="mb-1 font-medium">Connection diagnostics</h2>
        <p className="mb-2 text-xs text-muted-foreground">Live check of seller dependencies through the gateway.</p>
        <ul className="divide-y divide-border">
          <Diag label="Catalog (products/variants/stock)" status={dCatalog.data} />
          <Diag label="Coupons" status={dCoupon.data} />
          <Diag label="Shop service" status={dShop.data} />
          <Diag label="Media service" status={dMedia.data} gap="GAP-15/16" />
        </ul>
      </section>
    </div>
  );
}
