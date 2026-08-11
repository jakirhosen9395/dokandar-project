import Link from "next/link";
import { DEVOPS_SECTIONS, SERVICES } from "@/content/devops/services";

export default function DevopsHome() {
  return (
    <div>
      <h1 className="text-2xl font-semibold">Operational Handbook</h1>
      <p className="mt-2 text-muted-foreground">
        Internal portal for developers, DevOps, SREs, and QA · {SERVICES.length} services.
      </p>
      <div className="mt-6 grid grid-cols-1 gap-3 sm:grid-cols-2">
        {DEVOPS_SECTIONS.map((s) => (
          <Link key={s.slug} href={`/devops/${s.slug}`} className="rounded-lg border border-border p-4 hover:bg-muted">
            <div className="font-medium">{s.title}</div>
            <div className="text-sm text-muted-foreground">{s.desc}</div>
          </Link>
        ))}
      </div>
    </div>
  );
}
