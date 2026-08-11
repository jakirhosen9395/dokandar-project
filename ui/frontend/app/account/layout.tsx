import Link from "next/link";
import type { ReactNode } from "react";
import { SiteHeader } from "@/components/site-header";

// /account is gated to all authed roles by middleware (unauthed → /login).
const NAV = [
  { href: "/account", label: "Dashboard" },
  { href: "/account/profile", label: "Profile" },
  { href: "/account/orders", label: "Orders" },
  { href: "/account/wallet", label: "Wallet" },
  { href: "/account/addresses", label: "Addresses" },
  { href: "/account/notifications", label: "Notifications" },
  { href: "/account/reviews", label: "Reviews" },
  { href: "/wishlist", label: "Wishlist" },
];

export default function AccountLayout({ children }: { children: ReactNode }) {
  return (
    <>
      <SiteHeader />
      <div className="mx-auto flex max-w-6xl flex-col gap-6 px-4 py-6 md:flex-row">
        <aside className="shrink-0 md:w-52">
          <nav className="flex gap-2 overflow-x-auto md:flex-col md:gap-1" aria-label="Account navigation">
            {NAV.map((n) => (
              <Link key={n.href} href={n.href} className="whitespace-nowrap rounded px-3 py-1.5 text-sm hover:bg-muted">
                {n.label}
              </Link>
            ))}
            <Link href="/logout" className="whitespace-nowrap rounded px-3 py-1.5 text-sm text-red-500 hover:bg-muted">Log out</Link>
          </nav>
        </aside>
        <main className="min-w-0 flex-1">{children}</main>
      </div>
    </>
  );
}
