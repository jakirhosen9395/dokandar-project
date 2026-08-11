"use client";
import { useQuery } from "@tanstack/react-query";
import { SERVICES } from "@/content/devops/services";

export default function AdminSystem() {
  const data = useQuery({ queryKey: ["ops-data"], queryFn: async () => { const r = await fetch("/data"); return r.ok ? r.json() : null; } });
  const ready = useQuery({ queryKey: ["ops-ready"], queryFn: async () => { const r = await fetch("/ready"); return { ok: r.ok, status: r.status }; } });
  const d = data.data as { identity?: Record<string, unknown> } & Record<string, unknown> | null;
  const id = (k: string) => String(d?.identity?.[k] ?? d?.[k] ?? "—");

  return (
    <div className="space-y-6">
      <h1 className="text-xl font-semibold">System health</h1>
      <section className="grid grid-cols-2 gap-3 sm:grid-cols-4 text-sm">
        <div className="rounded-lg border border-border p-3"><div className="text-muted-foreground">Frontend ready</div><div className={`font-semibold ${ready.data?.ok ? "text-green-600" : "text-red-500"}`}>{ready.isLoading ? "…" : ready.data?.ok ? "healthy" : "degraded"}</div></div>
        <div className="rounded-lg border border-border p-3"><div className="text-muted-foreground">Code version</div><div className="font-semibold">{id("code_version")}</div></div>
        <div className="rounded-lg border border-border p-3"><div className="text-muted-foreground">Env</div><div className="font-semibold">{id("env")}</div></div>
        <div className="rounded-lg border border-border p-3"><div className="text-muted-foreground">Services</div><div className="font-semibold">{SERVICES.length}</div></div>
      </section>

      <section>
        <h2 className="mb-2 font-medium">Service catalog</h2>
        <div className="overflow-x-auto rounded-lg border border-border">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border bg-muted/50">
                <th className="px-3 py-2 text-left">#</th><th className="px-3 py-2 text-left">Service</th><th className="px-3 py-2 text-left">Language</th><th className="px-3 py-2 text-left">Ext REST</th>
              </tr>
            </thead>
            <tbody>
              {SERVICES.map((s) => (
                <tr key={s.id} className="border-b border-border last:border-0">
                  <td className="px-3 py-2 text-muted-foreground">{s.id.slice(0, 2)}</td>
                  <td className="px-3 py-2">{s.name}</td>
                  <td className="px-3 py-2 text-muted-foreground">{s.language}</td>
                  <td className="px-3 py-2 text-muted-foreground">{s.externalRest ?? "—"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p className="mt-1 text-xs text-muted-foreground">Per-service /health · /ready · /docs are proxied by the DEVOPS portal (server-side, by id). The detailed operational catalog lives at <a href="/devops" className="underline">/devops</a>.</p>
      </section>

      <section>
        <h2 className="mb-2 font-medium">Observability</h2>
        <div className="space-y-1 rounded-lg border border-dashed border-border p-4 text-sm text-muted-foreground">
          <p><strong className="text-foreground">Traces</strong> — Elastic APM, <code>service.name=dokandar-web</code>; Browser → BFF → Gateway → Service via W3C <code>traceparent</code> + <code>x-request-id</code>.</p>
          <p><strong className="text-foreground">Logs</strong> — Elasticsearch <code>logs-app-&lt;svc&gt;-*</code> + MongoDB forensic store, per service.</p>
          <p><strong className="text-foreground">Metrics</strong> — each service <code>/metrics</code> (Prometheus); RED + <code>&lt;svc&gt;_outbox_pending</code>.</p>
          <p className="text-amber-600">Kibana / APM / Grafana run on the internal ops network and are intentionally not browser-reachable — internal URLs are never exposed to the browser. Deep-linking is available via the ops VPN.</p>
        </div>
      </section>
    </div>
  );
}
