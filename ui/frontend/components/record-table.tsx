// Generic table for arrays of record objects whose exact shape isn't documented in OpenAPI — auto-columns
// from the first row. Honest rendering of real backend data without inventing a typed schema.
function fmt(v: unknown): string {
  if (v == null) return "—";
  if (typeof v === "object") return JSON.stringify(v).slice(0, 48);
  const s = String(v);
  return s.length > 48 ? `${s.slice(0, 48)}…` : s;
}

export function RecordTable({ rows, maxCols = 8 }: { rows: Record<string, unknown>[]; maxCols?: number }) {
  if (!rows.length) return <p className="py-4 text-center text-sm text-muted-foreground">No records.</p>;
  const cols = Object.keys(rows[0]).slice(0, maxCols);
  return (
    <div className="overflow-x-auto rounded-lg border border-border">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b border-border bg-muted/50">
            {cols.map((c) => <th key={c} className="px-3 py-2 text-left font-medium">{c}</th>)}
          </tr>
        </thead>
        <tbody>
          {rows.map((r, i) => (
            <tr key={i} className="border-b border-border last:border-0">
              {cols.map((c) => <td key={c} className="px-3 py-2 text-muted-foreground">{fmt(r[c])}</td>)}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
