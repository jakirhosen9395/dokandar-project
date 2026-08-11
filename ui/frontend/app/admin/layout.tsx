import Link from "next/link";
import type { ReactNode } from "react";
import { SiteHeader } from "@/components/site-header";

// /admin is gated to admin + platform_staff by middleware (others → /forbidden, unauth → /login).
const NAV = [
  { href: "/admin", label: "Overview" },
  { href: "/admin/users", label: "Users & KYC" },
  { href: "/admin/sellers", label: "Sellers" },
  { href: "/admin/orders", label: "Orders" },
  { href: "/admin/payments", label: "Payments" },
  { href: "/admin/wallets", label: "Wallets" },
  { href: "/admin/reports", label: "Reports" },
  { href: "/admin/risk", label: "Risk" },
  { href: "/admin/notifications", label: "Notifications" },
  { href: "/admin/system", label: "System" },
];

export default function AdminLayout({ children }: { children: ReactNode }) {
  return (
    <>
      <SiteHeader />
      <div className="mx-auto flex max-w-6xl flex-col gap-6 px-4 py-6 md:flex-row">
        <aside className="shrink-0 md:w-48">
          <div className="mb-2 px-3 text-xs font-semibold uppercase tracking-wide text-muted-foreground">Admin Console</div>
          <nav className="flex gap-2 overflow-x-auto md:flex-col md:gap-1" aria-label="Admin navigation">
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
