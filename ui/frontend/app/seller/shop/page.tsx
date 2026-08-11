"use client";
import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { getMyShops, createShop, updateShop, activateShop, type Shop, type ShopInput } from "@/lib/services/seller";

function errMsg(e: unknown): string {
  return e instanceof Error ? e.message : "Something went wrong. Please try again.";
}

export default function SellerShopPage() {
  const qc = useQueryClient();
  const shopsQ = useQuery({ queryKey: ["my-shops"], queryFn: getMyShops });
  const shop = (shopsQ.data?.shops ?? [])[0] as Shop | undefined;
  const invalidate = () => qc.invalidateQueries({ queryKey: ["my-shops"] });

  if (shopsQ.isLoading) return <div className="h-40 animate-pulse rounded-lg bg-muted" />;
  if (shopsQ.isError)
    return (
      <p className="text-sm text-red-600">
        Couldn&apos;t load your shop. <button onClick={() => shopsQ.refetch()} className="underline">Retry</button>
      </p>
    );

  return (
    <div className="space-y-5">
      <h1 className="text-xl font-semibold">My shop</h1>
      {shop ? <ShopEditor shop={shop} onDone={invalidate} /> : <ShopCreator onDone={invalidate} />}
    </div>
  );
}

function ShopCreator({ onDone }: { onDone: () => void }) {
  const [f, setF] = useState<ShopInput & { address_line: string }>({ handle: "", name: "", name_bn: "", description: "", contact_phone: "", contact_email: "", address_line: "" });
  const [err, setErr] = useState<string | null>(null);
  const set = (k: string, v: string) => setF((s) => ({ ...s, [k]: v }));

  const create = useMutation({
    mutationFn: () => {
      const body: ShopInput = {
        handle: f.handle.trim(),
        name: f.name.trim(),
        name_bn: f.name_bn?.trim() || undefined,
        description: f.description?.trim() || undefined,
        contact_phone: f.contact_phone?.trim() || undefined,
        contact_email: f.contact_email?.trim() || undefined,
        address: f.address_line.trim() ? [f.address_line.trim()] : undefined,
      };
      return createShop(body);
    },
    onSuccess: () => { setErr(null); onDone(); },
    onError: (e) => setErr(errMsg(e)),
  });

  function submit(e: React.FormEvent) {
    e.preventDefault();
    if (!/^[a-z0-9-]{3,}$/.test(f.handle.trim())) { setErr("Handle must be 3+ lowercase letters, numbers, or hyphens."); return; }
    if (f.name.trim().length < 2) { setErr("Shop name is required."); return; }
    setErr(null);
    create.mutate();
  }

  return (
    <section className="rounded-lg border border-border p-5">
      <h2 className="mb-1 font-medium">Create your shop</h2>
      <p className="mb-3 text-sm text-muted-foreground">Set up your shop to publish products for sale.</p>
      <form onSubmit={submit} className="space-y-3">
        <Field label="Handle (unique)" value={f.handle} onChange={(v) => set("handle", v.toLowerCase())} placeholder="my-shop" />
        <Field label="Shop name" value={f.name} onChange={(v) => set("name", v)} placeholder="My Shop" />
        <Field label="Shop name (Bangla)" value={f.name_bn ?? ""} onChange={(v) => set("name_bn", v)} placeholder="আমার দোকান" />
        <Field label="Description" value={f.description ?? ""} onChange={(v) => set("description", v)} />
        <Field label="Contact phone" value={f.contact_phone ?? ""} onChange={(v) => set("contact_phone", v)} placeholder="01XXXXXXXXX" />
        <Field label="Contact email" value={f.contact_email ?? ""} onChange={(v) => set("contact_email", v)} />
        <Field label="Address" value={f.address_line} onChange={(v) => set("address_line", v)} />
        {err ? <p className="text-sm text-red-600">{err}</p> : null}
        <button type="submit" disabled={create.isPending} className="rounded-md bg-foreground px-4 py-2 text-sm font-medium text-background hover:opacity-90 disabled:opacity-50">
          {create.isPending ? "Creating…" : "Create shop"}
        </button>
      </form>
    </section>
  );
}

function ShopEditor({ shop, onDone }: { shop: Shop; onDone: () => void }) {
  const [f, setF] = useState({ name: shop.name ?? "", name_bn: shop.name_bn ?? "", description: shop.description ?? "", contact_phone: shop.contact_phone ?? "", contact_email: shop.contact_email ?? "" });
  const [err, setErr] = useState<string | null>(null);
  const [ok, setOk] = useState(false);
  const set = (k: string, v: string) => setF((s) => ({ ...s, [k]: v }));
  const isLive = String(shop.status).toLowerCase() === "live" || String(shop.status).toLowerCase() === "active";

  const save = useMutation({
    mutationFn: () => updateShop(shop.id, f),
    onSuccess: () => { setErr(null); setOk(true); onDone(); setTimeout(() => setOk(false), 3000); },
    onError: (e) => setErr(errMsg(e)),
  });
  const activate = useMutation({ mutationFn: () => activateShop(shop.id), onSuccess: onDone, onError: (e) => setErr(errMsg(e)) });

  return (
    <>
      <section className="rounded-lg border border-border p-5">
        <div className="flex items-center justify-between">
          <div>
            <div className="text-lg font-semibold">{shop.name} <span className="text-sm text-muted-foreground">@{shop.handle}</span></div>
            <div className="mt-1 flex items-center gap-2 text-sm">
              <span aria-hidden className={`h-2.5 w-2.5 rounded-full ${isLive ? "bg-green-500" : "bg-amber-500"}`} />
              <span className={isLive ? "text-green-600" : "text-amber-600"}>{isLive ? "Live" : String(shop.status ?? "pending")}</span>
            </div>
          </div>
          {!isLive ? (
            <button onClick={() => activate.mutate()} disabled={activate.isPending} className="rounded-md border border-border px-3 py-1.5 text-sm hover:bg-muted disabled:opacity-50">
              {activate.isPending ? "Activating…" : "Activate shop"}
            </button>
          ) : null}
        </div>
      </section>

      <section className="rounded-lg border border-border p-5">
        <h2 className="mb-3 font-medium">Shop profile</h2>
        <form onSubmit={(e) => { e.preventDefault(); setOk(false); setErr(null); save.mutate(); }} className="space-y-3">
          <Field label="Shop name" value={f.name} onChange={(v) => set("name", v)} />
          <Field label="Shop name (Bangla)" value={f.name_bn} onChange={(v) => set("name_bn", v)} />
          <Field label="Description" value={f.description} onChange={(v) => set("description", v)} />
          <Field label="Contact phone" value={f.contact_phone} onChange={(v) => set("contact_phone", v)} />
          <Field label="Contact email" value={f.contact_email} onChange={(v) => set("contact_email", v)} />
          {err ? <p className="text-sm text-red-600">{err}</p> : null}
          {ok ? <p className="text-sm text-green-600">Shop updated.</p> : null}
          <button type="submit" disabled={save.isPending} className="rounded-md bg-foreground px-4 py-2 text-sm font-medium text-background hover:opacity-90 disabled:opacity-50">
            {save.isPending ? "Saving…" : "Save changes"}
          </button>
        </form>
      </section>
    </>
  );
}

function Field({ label, value, onChange, placeholder }: { label: string; value: string; onChange: (v: string) => void; placeholder?: string }) {
  return (
    <label className="block">
      <span className="mb-1 block text-sm text-muted-foreground">{label}</span>
      <input value={value} onChange={(e) => onChange(e.target.value)} placeholder={placeholder} className="w-full rounded-md border border-border px-3 py-1.5 text-sm outline-none focus:ring-2 focus:ring-ring" />
    </label>
  );
}
