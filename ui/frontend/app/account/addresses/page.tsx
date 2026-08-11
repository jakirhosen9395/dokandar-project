"use client";
import { useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createAddress, deleteAddress, getAddresses, getGeo, setDefaultAddress } from "@/lib/services/account";

const schema = z.object({
  label: z.string().min(1, "Required"),
  recipient_name: z.string().min(1, "Required"),
  recipient_phone: z.string().min(6, "Enter a phone"),
  division_code: z.string().min(1, "Select division"),
  district_code: z.string().min(1, "Select district"),
  upazila_code: z.string().min(1, "Select upazila"),
  union_code: z.string().optional(),
  line1: z.string().min(1, "Required"),
  line2: z.string().optional(),
  landmark: z.string().optional(),
  is_default: z.boolean().optional(),
});
type Form = z.infer<typeof schema>;

export default function AddressesPage() {
  const qc = useQueryClient();
  const [adding, setAdding] = useState(false);
  const addresses = useQuery({ queryKey: ["addresses"], queryFn: getAddresses });
  const items = (addresses.data?.items ?? []) as Record<string, unknown>[];
  const invalidate = () => qc.invalidateQueries({ queryKey: ["addresses"] });
  const del = useMutation({ mutationFn: (id: string) => deleteAddress(id), onSuccess: invalidate });
  const mkDefault = useMutation({ mutationFn: (id: string) => setDefaultAddress(id), onSuccess: invalidate });

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-semibold">Addresses</h1>
        <button onClick={() => setAdding((v) => !v)} className="rounded-md border border-border px-3 py-1.5 text-sm hover:bg-muted">
          {adding ? "Cancel" : "+ Add address"}
        </button>
      </div>

      {adding && <AddressForm onDone={() => { setAdding(false); invalidate(); }} />}

      {addresses.isLoading ? (
        <div className="h-24 animate-pulse rounded-lg bg-muted" />
      ) : items.length === 0 ? (
        <p className="py-6 text-center text-muted-foreground">No saved addresses.</p>
      ) : (
        <ul className="space-y-3">
          {items.map((a, i) => {
            const id = String(a.id ?? i);
            return (
              <li key={id} className="rounded-lg border border-border p-4 text-sm">
                <div className="flex items-start justify-between">
                  <div>
                    <div className="font-medium">{String(a.label ?? "Address")} {a.is_default ? <span className="ml-1 rounded bg-green-500/15 px-1.5 py-0.5 text-xs text-green-600">Default</span> : null}</div>
                    <div className="text-muted-foreground">{String(a.recipient_name ?? "")} · {String(a.recipient_phone ?? "")}</div>
                    <div className="text-muted-foreground">{String(a.line1 ?? "")}{a.line2 ? `, ${a.line2}` : ""}</div>
                  </div>
                  <div className="flex shrink-0 flex-col items-end gap-1">
                    {!a.is_default && <button onClick={() => mkDefault.mutate(id)} className="text-xs text-muted-foreground hover:underline">Set default</button>}
                    <button onClick={() => del.mutate(id)} className="text-xs text-red-500 hover:underline">Delete</button>
                  </div>
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}

function Select({ label, value, onChange, opts, disabled }: { label: string; value: string; onChange: (v: string) => void; opts: { code: string; name: string }[]; disabled?: boolean }) {
  return (
    <label className="block text-sm">
      <span className="mb-1 block text-muted-foreground">{label}</span>
      <select value={value} onChange={(e) => onChange(e.target.value)} disabled={disabled} className="w-full rounded-md border border-border bg-background px-3 py-2 disabled:opacity-50">
        <option value="">Select…</option>
        {opts.map((o) => <option key={o.code} value={o.code}>{o.name}</option>)}
      </select>
    </label>
  );
}

function AddressForm({ onDone }: { onDone: () => void }) {
  const { register, handleSubmit, watch, setValue, formState: { errors, isSubmitting } } = useForm<Form>({ resolver: zodResolver(schema) });
  const division = watch("division_code");
  const district = watch("district_code");
  const upazila = watch("upazila_code");

  const divisions = useQuery({ queryKey: ["geo", "div"], queryFn: () => getGeo("divisions") });
  const districts = useQuery({ queryKey: ["geo", "dist", division], enabled: !!division, queryFn: () => getGeo(`divisions/${division}/districts`) });
  const upazilas = useQuery({ queryKey: ["geo", "upa", district], enabled: !!district, queryFn: () => getGeo(`districts/${district}/upazilas`) });
  const unions = useQuery({ queryKey: ["geo", "uni", upazila], enabled: !!upazila, queryFn: () => getGeo(`upazilas/${upazila}/unions`) });
  const opts = (q: typeof divisions) => (q.data?.items ?? []).map((g) => ({ code: g.code, name: g.name_en || g.name_bn || g.code }));

  const create = useMutation({ mutationFn: (b: Form) => createAddress(b), onSuccess: onDone });

  return (
    <form onSubmit={handleSubmit((d) => create.mutate(d))} className="space-y-3 rounded-lg border border-border p-4">
      <div className="grid gap-3 sm:grid-cols-2">
        <input {...register("label")} placeholder="Label (Home, Office)" className="rounded-md border border-border bg-background px-3 py-2" />
        <input {...register("recipient_name")} placeholder="Recipient name" className="rounded-md border border-border bg-background px-3 py-2" />
        <input {...register("recipient_phone")} placeholder="Recipient phone" className="rounded-md border border-border bg-background px-3 py-2" />
        <input {...register("line1")} placeholder="Address line 1" className="rounded-md border border-border bg-background px-3 py-2" />
        <Select label="Division" value={division ?? ""} onChange={(v) => { setValue("division_code", v); setValue("district_code", ""); setValue("upazila_code", ""); }} opts={opts(divisions)} />
        <Select label="District" value={district ?? ""} onChange={(v) => { setValue("district_code", v); setValue("upazila_code", ""); }} opts={opts(districts)} disabled={!division} />
        <Select label="Upazila" value={upazila ?? ""} onChange={(v) => setValue("upazila_code", v)} opts={opts(upazilas)} disabled={!district} />
        <Select label="Union (optional)" value={watch("union_code") ?? ""} onChange={(v) => setValue("union_code", v)} opts={opts(unions)} disabled={!upazila} />
      </div>
      <label className="flex items-center gap-2 text-sm"><input type="checkbox" {...register("is_default")} /> Set as default</label>
      {Object.values(errors).length > 0 && <p className="text-sm text-red-500">{Object.values(errors)[0]?.message as string}</p>}
      {create.isError && <p className="text-sm text-red-500">Could not save address.</p>}
      <button disabled={isSubmitting || create.isPending} className="rounded-md bg-foreground px-4 py-2 text-sm font-medium text-background disabled:opacity-50">
        {create.isPending ? "Saving…" : "Save address"}
      </button>
    </form>
  );
}
