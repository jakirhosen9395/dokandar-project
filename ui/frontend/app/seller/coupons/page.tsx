"use client";
import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createCoupon, getMyCoupons, revokeCoupon, getMyShops, type Coupon } from "@/lib/services/seller";

export default function Coupons() {
  const qc = useQueryClient();
  const { data, isLoading } = useQuery({ queryKey: ["seller-coupons"], queryFn: getMyCoupons });
  const list = (Array.isArray(data) ? data : data?.items ?? []) as Coupon[];
  const revoke = useMutation({ mutationFn: (id: string) => revokeCoupon(id), onSuccess: () => qc.invalidateQueries({ queryKey: ["seller-coupons"] }) });

  const shopsQ = useQuery({ queryKey: ["my-shops"], queryFn: getMyShops });
  const shopId = (shopsQ.data?.shops ?? [])[0]?.id as string | undefined;

  const [form, setForm] = useState({ code: "", valuePercent: "10", minSpend: "", maxDiscount: "", validUntil: "" });
  const create = useMutation({
    mutationFn: () => {
      if (!shopId) throw new Error("Set up your shop first to create coupons.");
      const body: Record<string, unknown> = {
        code: form.code.trim().toUpperCase(),
        kind: "percent",
        scope: "shop",
        funded_by: "shopkeeper",
        shop_id: shopId,
        value_percent: Number(form.valuePercent),
        min_spend_minor: form.minSpend ? Math.round(Number(form.minSpend) * 100) : 0,
        valid_from: new Date().toISOString(),
        valid_until: form.validUntil ? new Date(`${form.validUntil}T23:59:59Z`).toISOString() : new Date(Date.now() + 1000 * 60 * 60 * 24 * 180).toISOString(),
        max_per_user: 1,
      };
      if (form.maxDiscount) body.max_discount_minor = Math.round(Number(form.maxDiscount) * 100);
      return createCoupon(body);
    },
    onSuccess: () => { setForm({ code: "", valuePercent: "10", minSpend: "", maxDiscount: "", validUntil: "" }); qc.invalidateQueries({ queryKey: ["seller-coupons"] }); },
  });

  return (
    <div className="space-y-5">
      <h1 className="text-xl font-semibold">Coupons</h1>
      <section className="rounded-lg border border-border p-4">
        <h2 className="mb-2 font-medium">Create coupon</h2>
        {!shopId && !shopsQ.isLoading ? (
          <p className="mb-2 text-sm text-amber-600">Set up your shop first to create coupons.</p>
        ) : null}
        <div className="flex flex-wrap gap-2">
          <input value={form.code} onChange={(e) => setForm({ ...form, code: e.target.value.toUpperCase() })} placeholder="CODE" aria-label="Coupon code" className="rounded-md border border-border bg-background px-3 py-2 text-sm" />
          <input value={form.valuePercent} onChange={(e) => setForm({ ...form, valuePercent: e.target.value })} placeholder="% off" aria-label="Percent off" className="w-20 rounded-md border border-border bg-background px-3 py-2 text-sm" />
          <input value={form.minSpend} onChange={(e) => setForm({ ...form, minSpend: e.target.value })} placeholder="Min spend ৳" aria-label="Minimum spend" className="w-28 rounded-md border border-border bg-background px-3 py-2 text-sm" />
          <input value={form.maxDiscount} onChange={(e) => setForm({ ...form, maxDiscount: e.target.value })} placeholder="Max disc. ৳" aria-label="Max discount" className="w-28 rounded-md border border-border bg-background px-3 py-2 text-sm" />
          <input type="date" value={form.validUntil} onChange={(e) => setForm({ ...form, validUntil: e.target.value })} aria-label="Valid until" className="rounded-md border border-border bg-background px-3 py-2 text-sm" />
          <button onClick={() => create.mutate()} disabled={!form.code || !shopId || create.isPending} className="rounded-md bg-foreground px-4 py-2 text-sm font-medium text-background disabled:opacity-50">{create.isPending ? "…" : "Create"}</button>
        </div>
        {create.isError && <p className="mt-2 text-sm text-red-600">{create.error instanceof Error ? create.error.message : "Coupon creation failed."}</p>}
        {create.isSuccess && <p className="mt-2 text-sm text-green-600">Created — pending admin approval.</p>}
      </section>
      <section>
        <h2 className="mb-2 font-medium">My coupons</h2>
        {isLoading ? (
          <div className="h-20 animate-pulse rounded bg-muted" />
        ) : list.length === 0 ? (
          <p className="text-sm text-muted-foreground">No coupons yet.</p>
        ) : (
          <ul className="divide-y divide-border rounded-lg border border-border text-sm">
            {list.map((c, i) => (
              <li key={c.id ?? i} className="flex items-center justify-between p-3">
                <span><span className="font-medium">{c.code ?? "—"}</span>{c.valuePercent != null ? ` · ${c.valuePercent}%` : ""} <span className="text-muted-foreground">· {c.status ?? ""}</span></span>
                {c.id && c.status !== "revoked" && <button onClick={() => revoke.mutate(c.id!)} className="text-xs text-red-500 hover:underline">Revoke</button>}
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}
