import Link from "next/link";
import type { ReactNode } from "react";
import { SiteHeader } from "@/components/site-header";

// /seller is gated to shopkeeper + shop_staff by middleware (customer → /forbidden, unauth → /login).
const NAV = [
  { href: "/seller", label: "Dashboard" },
  { href: "/seller/products", label: "Products" },
  { href: "/seller/inventory", label: "Inventory" },
  { href: "/seller/orders", label: "Orders" },
  { href: "/seller/coupons", label: "Coupons" },
  { href: "/seller/media", label: "Media" },
  { href: "/seller/analytics", label: "Analytics" },
];

export default function SellerLayout({ children }: { children: ReactNode }) {
  return (
    <>
      <SiteHeader />
      <div className="mx-auto flex max-w-6xl flex-col gap-6 px-4 py-6 md:flex-row">
        <aside className="shrink-0 md:w-52">
          <div className="mb-2 px-3 text-xs font-semibold uppercase tracking-wide text-muted-foreground">Seller Central</div>
          <nav className="flex gap-2 overflow-x-auto md:flex-col md:gap-1" aria-label="Seller navigation">
            {NAV.map((n) => (
              <Link key={n.href} href={n.href} className="whitespace-nowrap rounded px-3 py-1.5 text-sm hover:bg-muted">{n.label}</Link>
            ))}
          </nav>
        </aside>
        <main className="min-w-0 flex-1">{children}</main>
      </div>
    </>
  );
}
