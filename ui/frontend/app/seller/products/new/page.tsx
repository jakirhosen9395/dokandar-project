"use client";
import { useRouter } from "next/navigation";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod";
import { useMutation, useQuery } from "@tanstack/react-query";
import { createProduct, getCategoriesTree, type SellerCategory } from "@/lib/services/seller";

const schema = z.object({
  name_en: z.string().min(1, "Required"),
  name_bn: z.string().min(1, "Required"),
  category_id: z.string().uuid("Select a category"),
  list_price_minor: z.coerce.number().int().positive("Enter a price in paisa"),
  sale_price_minor: z.coerce.number().int().nonnegative().optional(),
  brand: z.string().optional(),
  sku: z.string().optional(),
  description_en: z.string().optional(),
  description_bn: z.string().optional(),
});
type Form = z.infer<typeof schema>;

function flatten(cats: SellerCategory[], depth = 0): { id: string; label: string }[] {
  return cats.flatMap((c) => [{ id: c.category_id, label: `${"— ".repeat(depth)}${c.name_en}` }, ...flatten(c.children ?? [], depth + 1)]);
}

export default function NewProduct() {
  const router = useRouter();
  const cats = useQuery({ queryKey: ["categories-tree"], queryFn: getCategoriesTree });
  const options = flatten(cats.data?.tree ?? []);
  const { register, handleSubmit, formState: { errors } } = useForm<Form>({ resolver: zodResolver(schema) });
  const create = useMutation({
    mutationFn: (b: Form) => createProduct(b),
    onSuccess: (r) => { const id = r?.product?.id; router.push(id ? `/seller/products/${id}` : "/seller/products"); },
  });

  return (
    <div className="max-w-lg space-y-4">
      <h1 className="text-xl font-semibold">New product</h1>
      <p className="text-xs text-muted-foreground">Creates a <strong>draft</strong> product. Listing it for sale unlocks once shop setup is enabled for your account.</p>
      <form onSubmit={handleSubmit((d) => create.mutate(d))} className="space-y-3">
        <input {...register("name_en")} placeholder="Name (English)" className="w-full rounded-md border border-border bg-background px-3 py-2" />
        <input {...register("name_bn")} placeholder="নাম (বাংলা)" className="w-full rounded-md border border-border bg-background px-3 py-2" />
        <select {...register("category_id")} className="w-full rounded-md border border-border bg-background px-3 py-2">
          <option value="">Select category…</option>
          {options.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}
        </select>
        <div className="flex gap-3">
          <input {...register("list_price_minor")} placeholder="List price (paisa)" className="flex-1 rounded-md border border-border bg-background px-3 py-2" />
          <input {...register("sale_price_minor")} placeholder="Sale price (paisa)" className="flex-1 rounded-md border border-border bg-background px-3 py-2" />
        </div>
        <div className="flex gap-3">
          <input {...register("brand")} placeholder="Brand" className="flex-1 rounded-md border border-border bg-background px-3 py-2" />
          <input {...register("sku")} placeholder="SKU" className="flex-1 rounded-md border border-border bg-background px-3 py-2" />
        </div>
        <textarea {...register("description_en")} placeholder="Description (English)" rows={3} className="w-full rounded-md border border-border bg-background px-3 py-2" />
        {Object.values(errors)[0] && <p className="text-sm text-red-500">{Object.values(errors)[0]?.message as string}</p>}
        {create.isError && <p className="text-sm text-red-500">Could not create product (backend rejected the request).</p>}
        <button disabled={create.isPending} className="rounded-md bg-foreground px-4 py-2 text-sm font-medium text-background disabled:opacity-50">{create.isPending ? "Creating…" : "Create draft"}</button>
      </form>
    </div>
  );
}
