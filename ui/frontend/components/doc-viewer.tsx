"use client";
import { useMemo, useState, type ReactNode } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

function text(n: ReactNode): string {
  if (typeof n === "string" || typeof n === "number") return String(n);
  if (Array.isArray(n)) return n.map(text).join("");
  if (n && typeof n === "object" && "props" in n) return text((n as { props: { children: ReactNode } }).props.children);
  return "";
}
const slug = (n: ReactNode) => text(n).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "");

export function DocViewer({ markdown }: { markdown: string }) {
  const [q, setQ] = useState("");
  const toc = useMemo(
    () => markdown.split("\n").filter((l) => /^#{2,3}\s/.test(l)).map((l) => {
      const level = (l.match(/^#+/)?.[0].length ?? 2);
      const t = l.replace(/^#+\s/, "").replace(/[*`]/g, "").trim();
      return { level, text: t, id: t.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "") };
    }),
    [markdown],
  );
  const filtered = q ? toc.filter((t) => t.text.toLowerCase().includes(q.toLowerCase())) : toc;

  return (
    <div className="flex flex-col gap-6 lg:flex-row">
      <aside className="shrink-0 lg:sticky lg:top-20 lg:w-56 lg:self-start">
        <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Filter sections…" aria-label="Filter sections" className="mb-2 w-full rounded-md border border-border bg-background px-2 py-1 text-xs" />
        <nav className="max-h-[60vh] space-y-1 overflow-y-auto text-xs" aria-label="Table of contents">
          {filtered.map((t, i) => <a key={i} href={`#${t.id}`} className={`block hover:underline ${t.level === 3 ? "pl-3 text-muted-foreground" : "font-medium"}`}>{t.text}</a>)}
        </nav>
      </aside>
      <article className="min-w-0 flex-1">
        <ReactMarkdown
          remarkPlugins={[remarkGfm]}
          components={{
            h1: ({ children }) => <h1 className="mb-3 text-xl font-bold">{children}</h1>,
            h2: ({ children }) => <h2 id={slug(children)} className="mb-2 mt-6 scroll-mt-20 text-lg font-semibold">{children}</h2>,
            h3: ({ children }) => <h3 id={slug(children)} className="mb-1 mt-4 scroll-mt-20 font-medium">{children}</h3>,
            p: ({ children }) => <p className="mb-3 text-sm text-muted-foreground">{children}</p>,
            code: ({ children }) => <code className="rounded bg-muted px-1 py-0.5 text-xs">{children}</code>,
            pre: ({ children }) => <pre className="mb-3 overflow-x-auto rounded-lg border border-border bg-muted/50 p-3 text-xs">{children}</pre>,
            ul: ({ children }) => <ul className="mb-3 ml-5 list-disc text-sm text-muted-foreground">{children}</ul>,
            ol: ({ children }) => <ol className="mb-3 ml-5 list-decimal text-sm text-muted-foreground">{children}</ol>,
            li: ({ children }) => <li className="mb-1">{children}</li>,
            table: ({ children }) => <div className="overflow-x-auto"><table className="mb-3 w-full border-collapse text-xs">{children}</table></div>,
            th: ({ children }) => <th className="border border-border px-2 py-1 text-left font-medium">{children}</th>,
            td: ({ children }) => <td className="border border-border px-2 py-1 text-muted-foreground">{children}</td>,
            a: ({ href, children }) => <a href={href} className="text-blue-500 underline">{children}</a>,
            strong: ({ children }) => <strong className="font-semibold text-foreground">{children}</strong>,
          }}
        >
          {markdown}
        </ReactMarkdown>
      </article>
    </div>
  );
}
