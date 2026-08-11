import Link from "next/link";
import type { ReactNode } from "react";
import { DEVOPS_SECTIONS } from "@/content/devops/services";

/** DEVOPS shell. Route access is enforced by middleware (admin | platform_staff). Foundation: nav + sections. */
export default function DevopsLayout({ children }: { children: ReactNode }) {
  return (
    <div className="flex min-h-screen bg-background text-foreground">
      <aside className="w-64 shrink-0 border-r border-border p-4">
        <Link href="/devops" className="mb-4 block font-semibold">
          DOKANDAR · DEVOPS
        </Link>
        <nav className="space-y-1 text-sm">
          {DEVOPS_SECTIONS.map((s) => (
            <Link key={s.slug} href={`/devops/${s.slug}`} className="block rounded px-2 py-1.5 hover:bg-muted">
              {s.title}
            </Link>
          ))}
        </nav>
        <p className="mt-6 text-xs text-muted-foreground">Internal · admin / platform_staff only</p>
      </aside>
      <main className="max-w-5xl flex-1 p-8">{children}</main>
    </div>
  );
}
