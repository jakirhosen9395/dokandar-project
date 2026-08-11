import type { ReactNode } from "react";

// Production blocked-state: clean, user-facing copy + what still works. Internal tracking IDs and the
// backend resolution are tucked into a collapsible "Technical details" so end users never see jargon.
export interface Remediation {
  title: string;
  why: string;
  stillWorks?: string[];
  action?: ReactNode;
  // operator-only context (not shown by default)
  category?: "B" | "C";
  gap?: string;
  owner?: string;
  recommendedFix?: string;
}

export function RemediationCard({ title, why, stillWorks, action, category, gap, owner, recommendedFix }: Remediation) {
  const hasTech = gap || owner || recommendedFix;
  return (
    <div className="rounded-lg border border-border bg-muted/30 p-5">
      <div className="flex flex-wrap items-center gap-2">
        <span aria-hidden className="text-lg">⏳</span>
        <h2 className="font-semibold">{title}</h2>
        <span className="ml-auto rounded-full bg-muted px-2 py-0.5 text-xs font-medium text-muted-foreground">Coming soon</span>
      </div>
      <p className="mt-2 text-sm text-muted-foreground">{why}</p>
      {stillWorks?.length ? (
        <p className="mt-3 text-sm"><span className="font-medium text-green-600">Available now:</span> <span className="text-muted-foreground">{stillWorks.join(" · ")}</span></p>
      ) : null}
      {action ? <div className="mt-4">{action}</div> : null}
      {hasTech ? (
        <details className="mt-4 text-xs text-muted-foreground">
          <summary className="cursor-pointer select-none">Technical details</summary>
          <dl className="mt-2 space-y-1">
            {gap ? <div><span className="font-medium">Tracking:</span> {gap}{category ? ` · Category ${category}` : ""}</div> : null}
            {owner ? <div><span className="font-medium">Owner:</span> {owner}</div> : null}
            {recommendedFix ? <div><span className="font-medium">Resolution:</span> {recommendedFix}</div> : null}
          </dl>
        </details>
      ) : null}
    </div>
  );
}
