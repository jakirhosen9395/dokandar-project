"use client";
import { use, useEffect, useState } from "react";
import { useForm } from "react-hook-form";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { getProduct, updateProduct, setStock, setProductStatus, addVariant, deleteVariant, type CatProduct } from "@/lib/services/seller";

type EditForm = { name_en?: string; name_bn?: string; brand?: string; list_price_minor?: number; sale_price_minor?: number };

function StockAdjust({ onSet }: { onSet: (q: number) => void }) {
  const [v, setV] = useState("");
  return (
    <div className="flex gap-1">
      <input value={v} onChange={(e) => setV(e.target.value)} placeholder="qty" aria-label="Set stock" className="w-16 rounded border border-border bg-background px-2 py-1" />
      <button onClick={() => { const n = parseInt(v, 10); if (!Number.isNaN(n)) onSet(n); }} className="rounded border border-border px-2 py-1 text-xs hover:bg-muted">Set</button>
    </div>
  );
}

export default function SellerProductDetail({ params }: { params: Promise<{ productId: string }> }) {
  const { productId } = use(params);
  const qc = useQueryClient();
  const { data, isLoading } = useQuery({ queryKey: ["seller-product", productId], queryFn: () => getProduct(productId) });
  const p = ((data as { product?: CatProduct })?.product ?? data) as CatProduct | null;
  const { register, handleSubmit, reset } = useForm<EditForm>();

  useEffect(() => {
    if (p?.id) reset({ name_en: p.name_en, name_bn: p.name_bn, brand: p.brand ?? "", list_price_minor: p.list_price_minor ?? undefined, sale_price_minor: p.sale_price_minor ?? undefined });
  }, [p, reset]);

  const save = useMutation({
    mutationFn: (b: EditForm) => updateProduct(productId, { ...b, list_price_minor: Number(b.list_price_minor), sale_price_minor: b.sale_price_minor ? Number(b.sale_price_minor) : undefined }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["seller-product", productId] }),
  });
  const stock = useMutation({
    mutationFn: ({ vid, quantity }: { vid: string; quantity: number }) => setStock(vid, quantity),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["seller-product", productId] }),
  });
  const invalidate = () => qc.invalidateQueries({ queryKey: ["seller-product", productId] });
  const publish = useMutation({ mutationFn: (active: boolean) => setProductStatus(productId, active ? "active" : "draft"), onSuccess: invalidate });
  const delVariant = useMutation({ mutationFn: (vid: string) => deleteVariant(productId, vid), onSuccess: invalidate });

  if (isLoading) return <div className="h-40 animate-pulse rounded bg-muted" />;
  if (!p?.id) return <p className="text-muted-foreground">Product not found.</p>;
  const variants = p.variants ?? [];
  const isActive = String(p.status).toLowerCase() === "active";

  return (
    <div className="max-w-lg space-y-5">
      <div className="flex items-center gap-2">
        <h1 className="text-xl font-semibold">Edit product</h1>
        <span className={`rounded-full px-2 py-0.5 text-xs ${isActive ? "bg-green-100 text-green-700" : "bg-muted"}`}>{p.status ?? "—"}</span>
        <button onClick={() => publish.mutate(!isActive)} disabled={publish.isPending} className="ml-auto rounded-md border border-border px-3 py-1 text-sm hover:bg-muted disabled:opacity-50">
          {publish.isPending ? "…" : isActive ? "Unpublish" : "Publish for sale"}
        </button>
      </div>
      <form onSubmit={handleSubmit((d) => save.mutate(d))} className="space-y-3">
        <input {...register("name_en")} className="w-full rounded-md border border-border bg-background px-3 py-2" />
        <input {...register("name_bn")} className="w-full rounded-md border border-border bg-background px-3 py-2" />
        <input {...register("brand")} placeholder="Brand" className="w-full rounded-md border border-border bg-background px-3 py-2" />
        <div className="flex gap-3">
          <input {...register("list_price_minor")} placeholder="List (paisa)" className="flex-1 rounded-md border border-border bg-background px-3 py-2" />
          <input {...register("sale_price_minor")} placeholder="Sale (paisa)" className="flex-1 rounded-md border border-border bg-background px-3 py-2" />
        </div>
        {save.isSuccess && <p className="text-sm text-green-600">Saved.</p>}
        {save.isError && <p className="text-sm text-red-500">Save failed.</p>}
        <button disabled={save.isPending} className="rounded-md bg-foreground px-4 py-2 text-sm font-medium text-background disabled:opacity-50">{save.isPending ? "Saving…" : "Save"}</button>
      </form>
      <section>
        <h2 className="mb-2 font-medium">Variants &amp; stock</h2>
        {variants.length === 0 ? (
          <p className="text-sm text-muted-foreground">No variants yet.</p>
        ) : (
          <ul className="divide-y divide-border rounded-lg border border-border text-sm">
            {variants.map((v) => (
              <li key={v.id} className="flex items-center justify-between gap-2 p-3">
                <span className="font-mono text-xs">{String(v.sku ?? v.id).slice(0, 16)}</span>
                <div className="flex items-center gap-2">
                  <StockAdjust onSet={(q) => stock.mutate({ vid: v.id, quantity: q })} />
                  <button onClick={() => delVariant.mutate(v.id)} className="text-xs text-red-500 hover:underline">remove</button>
                </div>
              </li>
            ))}
          </ul>
        )}
        <VariantAdd onAdd={(b) => addVariant(productId, b).then(invalidate)} defaultList={p.list_price_minor ?? undefined} defaultSale={p.sale_price_minor ?? undefined} />
        {stock.isError ? <p className="mt-1 text-xs text-red-500">Stock update failed.</p> : null}
      </section>
    </div>
  );
}

function VariantAdd({ onAdd, defaultList, defaultSale }: { onAdd: (b: { sku: string; list_price_minor: number; sale_price_minor?: number }) => Promise<unknown>; defaultList?: number; defaultSale?: number }) {
  const [sku, setSku] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function add() {
    if (sku.trim().length < 2) { setErr("Enter a SKU."); return; }
    setBusy(true); setErr(null);
    try {
      await onAdd({ sku: sku.trim(), list_price_minor: Number(defaultList ?? 0), sale_price_minor: defaultSale ? Number(defaultSale) : undefined });
      setSku("");
    } catch (e) { setErr(e instanceof Error ? e.message : "Add failed."); }
    finally { setBusy(false); }
  }
  return (
    <div className="mt-3 flex items-center gap-2">
      <input value={sku} onChange={(e) => setSku(e.target.value)} placeholder="New variant SKU" className="w-40 rounded border border-border bg-background px-2 py-1 text-sm" />
      <button onClick={add} disabled={busy} className="rounded border border-border px-2 py-1 text-xs hover:bg-muted disabled:opacity-50">{busy ? "Adding…" : "Add variant"}</button>
      {err ? <span className="text-xs text-red-500">{err}</span> : null}
    </div>
  );
}
