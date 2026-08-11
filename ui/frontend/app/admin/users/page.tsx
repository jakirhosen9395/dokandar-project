"use client";
import { useState } from "react";
import { useRouter } from "next/navigation";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { approveKyc, getKycQueue, rejectKyc } from "@/lib/services/admin";

export default function AdminUsers() {
  const qc = useQueryClient();
  const router = useRouter();
  const kyc = useQuery({ queryKey: ["kyc-queue"], queryFn: getKycQueue });
  const items = (kyc.data?.items ?? []) as Record<string, unknown>[];
  const inv = () => qc.invalidateQueries({ queryKey: ["kyc-queue"] });
  const approve = useMutation({ mutationFn: (id: string) => approveKyc(id), onSuccess: inv });
  const reject = useMutation({ mutationFn: (id: string) => rejectKyc(id), onSuccess: inv });
  const [uid, setUid] = useState("");

  return (
    <div className="space-y-6">
      <h1 className="text-xl font-semibold">Users &amp; KYC</h1>
      <section className="rounded-lg border border-border p-4">
        <h2 className="mb-2 font-medium">Look up a user</h2>
        <div className="flex gap-2">
          <input value={uid} onChange={(e) => setUid(e.target.value)} placeholder="user id (uuid)" aria-label="User id" className="flex-1 rounded-md border border-border bg-background px-3 py-2 text-sm" />
          <button onClick={() => uid && router.push(`/admin/users/${uid}`)} className="rounded-md bg-foreground px-4 py-2 text-sm text-background">View</button>
        </div>
        <p className="mt-1 text-xs text-muted-foreground">Look up a user by id — profile and wallet appear on the detail page. A browsable user directory is coming soon.</p>
      </section>
      <section>
        <h2 className="mb-2 font-medium">KYC queue <span className="text-sm font-normal text-muted-foreground">({items.length})</span></h2>
        {kyc.isLoading ? (
          <div className="h-20 animate-pulse rounded bg-muted" />
        ) : items.length === 0 ? (
          <p className="text-sm text-muted-foreground">Queue is empty.</p>
        ) : (
          <ul className="divide-y divide-border rounded-lg border border-border text-sm">
            {items.map((it, i) => {
              const id = String(it.submission_id ?? it.id ?? i);
              return (
                <li key={id} className="flex items-center justify-between p-3">
                  <div>
                    <div className="font-medium">{String(it.user_id ?? it.subject ?? id).slice(0, 12)}</div>
                    <div className="text-xs text-muted-foreground">{String(it.kind ?? it.doc_type ?? it.status ?? "")}</div>
                  </div>
                  <div className="flex gap-2">
                    <button onClick={() => approve.mutate(id)} className="rounded border border-border px-2 py-1 text-xs text-green-600 hover:bg-muted">Approve</button>
                    <button onClick={() => reject.mutate(id)} className="rounded border border-border px-2 py-1 text-xs text-red-500 hover:bg-muted">Reject</button>
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </section>
    </div>
  );
}
