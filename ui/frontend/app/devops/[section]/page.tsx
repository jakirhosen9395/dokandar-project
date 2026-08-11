import { notFound } from "next/navigation";
import Link from "next/link";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { DEVOPS_SECTIONS, OPS_ENDPOINTS, SERVICES } from "@/content/devops/services";
import {
  API_STATS, BOUNDARIES, EVENT_FLOW, INFRASTRUCTURE, LOCAL_DEV, OBSERVABILITY, REQUEST_FLOW, RUNBOOKS, SAGA_STEPS, TOTAL_ENDPOINTS,
} from "@/content/devops/handbook";
import { DocViewer } from "@/components/doc-viewer";

const DOCS = [
  { slug: "architecture", title: "Frontend Architecture", file: "FRONTEND_ARCHITECTURE.md" },
  { slug: "commands", title: "COMMAND.md", file: "COMMAND.md" },
  { slug: "readme", title: "README", file: "README.md" },
  { slug: "adr-0001", title: "ADR 0001 — Foundation", file: "docs/adr/0001-frontend-foundation.md" },
];

function Flow({ title, items }: { title: string; items: readonly string[] }) {
  return (
    <section className="mb-6">
      <h2 className="mb-2 font-medium">{title}</h2>
      <ol className="space-y-2">
        {items.map((s, i) => (
          <li key={i} className="flex gap-3 rounded-lg border border-border p-3 text-sm">
            <span className="shrink-0 font-mono text-xs text-muted-foreground">{String(i + 1).padStart(2, "0")}</span>
            <span className="text-muted-foreground">{s}</span>
          </li>
        ))}
      </ol>
    </section>
  );
}

async function DocsSection({ doc }: { doc?: string }) {
  const current = DOCS.find((d) => d.slug === doc) ?? DOCS[0];
  let md: string | null = null;
  try { md = await readFile(join(process.cwd(), current.file), "utf8"); } catch { md = null; }
  return (
    <div>
      <nav className="mb-4 flex flex-wrap gap-2 text-sm" aria-label="Documents">
        {DOCS.map((d) => (
          <Link key={d.slug} href={`/devops/docs?doc=${d.slug}`} className={`rounded border px-3 py-1.5 ${d.slug === current.slug ? "border-foreground bg-muted font-medium" : "border-border hover:bg-muted"}`}>{d.title}</Link>
        ))}
      </nav>
      {md ? <DocViewer markdown={md} /> : <p className="text-sm text-muted-foreground">Document not available in this image. (overview/*.md live in a separate spec repo; in-repo docs are rendered here.)</p>}
    </div>
  );
}

export default async function DevopsSection({ params, searchParams }: { params: Promise<{ section: string }>; searchParams: Promise<{ doc?: string }> }) {
  const { section } = await params;
  const meta = DEVOPS_SECTIONS.find((s) => s.slug === section);
  if (!meta) notFound();
  const sp = await searchParams;

  return (
    <div>
      <h1 className="text-2xl font-semibold">{meta.title}</h1>
      <p className="mt-2 text-muted-foreground">{meta.desc}</p>
      <div className="mt-6">
        {section === "architecture" ? (
          <>
            <Flow title="Service boundaries" items={BOUNDARIES} />
            <Flow title="Request flow (north–south)" items={REQUEST_FLOW} />
            <Flow title="Event flow (east–west)" items={EVENT_FLOW} />
            <Flow title="Checkout saga (13-order, Temporal)" items={SAGA_STEPS} />
          </>
        ) : section === "catalog" ? (
          <div className="overflow-x-auto rounded-lg border border-border">
            <table className="w-full text-sm">
              <thead><tr className="border-b border-border bg-muted/50 text-left"><th className="px-3 py-2">Service</th><th className="px-3 py-2">Language</th><th className="px-3 py-2">Framework</th><th className="px-3 py-2">REST·gRPC</th><th className="px-3 py-2">Datastores</th><th className="px-3 py-2">Owner</th></tr></thead>
              <tbody>
                {SERVICES.map((s) => (
                  <tr key={s.id} className="border-b border-border/50 last:border-0">
                    <td className="px-3 py-2 font-medium">{s.id}</td>
                    <td className="px-3 py-2 text-muted-foreground">{s.language}</td>
                    <td className="px-3 py-2 text-muted-foreground">{s.framework}</td>
                    <td className="px-3 py-2 tabular-nums text-muted-foreground">{s.externalRest}{s.externalGrpc ? ` · ${s.externalGrpc}` : ""}</td>
                    <td className="px-3 py-2 text-muted-foreground">{s.datastores.join(", ")}</td>
                    <td className="px-3 py-2 text-muted-foreground">{s.owner}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : section === "api-explorer" ? (
          <>
            <p className="mb-3 text-sm text-muted-foreground">{TOTAL_ENDPOINTS} business endpoints across 19 specs. Live OpenAPI is rendered through the server-side proxy <code>/api/devops/openapi/&lt;svc&gt;</code> (admin/platform_staff only — never exposes host:port).</p>
            <div className="overflow-x-auto rounded-lg border border-border">
              <table className="w-full text-sm">
                <thead><tr className="border-b border-border bg-muted/50 text-left"><th className="px-3 py-2">Service</th><th className="px-3 py-2">Base path</th><th className="px-3 py-2">Endpoints</th><th className="px-3 py-2">OpenAPI</th></tr></thead>
                <tbody>
                  {SERVICES.map((s) => {
                    const st = API_STATS[s.id];
                    return (
                      <tr key={s.id} className="border-b border-border/50 last:border-0">
                        <td className="px-3 py-2 font-medium">{s.id}</td>
                        <td className="px-3 py-2 font-mono text-xs text-muted-foreground">{st?.base ?? "—"}</td>
                        <td className="px-3 py-2 tabular-nums text-muted-foreground">{st?.endpoints ?? "—"}</td>
                        <td className="px-3 py-2"><a href={`/api/devops/openapi/${s.id}`} className="text-blue-500 underline" target="_blank" rel="noreferrer">openapi.json</a></td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          </>
        ) : section === "ops-endpoints" ? (
          <>
            <p className="mb-3 text-sm text-muted-foreground">Every service exposes the same five public, no-auth root endpoints (the operational contract):</p>
            <ul className="space-y-2 text-sm">
              {[["/ready", "LB readiness gate — 200 only when every traffic-gating dep is reachable. Drives the container HEALTHCHECK."], ["/health", "Full diagnostics over all deps + an observability block (grpc peer checks are diagnostic-only)."], ["/data", "Identity block + the read-only data/<tenant>/result.json snapshot."], ["/metrics", "Prometheus text — RED + <svc>_outbox_pending, closed-set labels only."], ["/docs + /openapi.json", "Swagger; every served route appears in the spec."]].map(([e, d]) => (
                <li key={e} className="rounded-lg border border-border p-3"><code className="text-foreground">{e}</code><span className="ml-2 text-muted-foreground">{d}</span></li>
              ))}
            </ul>
            <p className="mt-3 text-xs text-muted-foreground">This frontend exposes /health · /ready · /data ({OPS_ENDPOINTS.length}-endpoint contract). Per-service ops live behind the gateway on the internal network.</p>
          </>
        ) : section === "infrastructure" ? (
          <ul className="space-y-2">
            {INFRASTRUCTURE.map((d) => (
              <li key={d.name} className="rounded-lg border border-border p-3 text-sm"><span className="font-medium">{d.name}</span><span className="ml-2 text-muted-foreground">{d.role}</span></li>
            ))}
          </ul>
        ) : section === "observability" ? (
          <div className="space-y-3">
            {Object.entries(OBSERVABILITY).map(([k, v]) => (
              <div key={k} className="rounded-lg border border-border p-3 text-sm"><div className="font-medium capitalize">{k}</div><p className="mt-1 text-muted-foreground">{v}</p></div>
            ))}
          </div>
        ) : section === "local-dev" ? (
          <>
            <div className="mb-3 rounded-lg border border-border p-3 text-sm"><span className="font-medium">Startup order:</span> <span className="text-muted-foreground">{LOCAL_DEV.startupOrder}</span></div>
            <Flow title="Steps" items={LOCAL_DEV.steps} />
          </>
        ) : section === "runbooks" ? (
          <div className="space-y-3">
            {RUNBOOKS.map((r) => (
              <details key={r.id} className="rounded-lg border border-border p-3 text-sm">
                <summary className="cursor-pointer font-medium">{r.title}</summary>
                <ol className="mt-2 ml-5 list-decimal space-y-1 text-muted-foreground">{r.steps.map((s, i) => <li key={i}>{s}</li>)}</ol>
              </details>
            ))}
          </div>
        ) : section === "docs" ? (
          <DocsSection doc={sp.doc} />
        ) : (
          <div className="rounded-lg border border-dashed border-border p-8 text-center text-muted-foreground">Section not found.</div>
        )}
      </div>
    </div>
  );
}
