"use client";
import { useEffect } from "react";
import { useForm } from "react-hook-form";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { getProfile, updateProfile } from "@/lib/services/account";
import { useAuth } from "@/hooks/use-auth";

type Form = { name_en?: string; name_bn?: string; gender?: string; dob?: string; whatsapp_number?: string };

export default function ProfilePage() {
  const { user } = useAuth();
  const qc = useQueryClient();
  const profile = useQuery({ queryKey: ["profile"], queryFn: getProfile });
  const { register, handleSubmit, reset, formState: { isSubmitting } } = useForm<Form>();
  const p = profile.data as Record<string, unknown> | null;

  useEffect(() => {
    if (p && !p.error) reset({ name_en: p.name_en as string, name_bn: p.name_bn as string, gender: p.gender as string, dob: p.dob as string, whatsapp_number: p.whatsapp_number as string });
  }, [p, reset]);

  const save = useMutation({ mutationFn: (b: Form) => updateProfile(b), onSuccess: () => qc.invalidateQueries({ queryKey: ["profile"] }) });

  return (
    <div className="max-w-md space-y-4">
      <h1 className="text-xl font-semibold">Profile</h1>
      <div className="rounded-lg border border-border p-4 text-sm">
        <div>Phone: {user?.phone}</div>
        <div className="text-muted-foreground">Role: {user?.role} · KYC: {user?.kyc ?? "—"}</div>
      </div>
      {p?.error ? <p className="text-sm text-muted-foreground">Your profile is still syncing (it lands shortly after signup). You can edit it below.</p> : null}
      <form onSubmit={handleSubmit((d) => save.mutate(d))} className="space-y-3">
        <input {...register("name_en")} placeholder="Name (English)" className="w-full rounded-md border border-border bg-background px-3 py-2" />
        <input {...register("name_bn")} placeholder="নাম (বাংলা)" className="w-full rounded-md border border-border bg-background px-3 py-2" />
        <input {...register("whatsapp_number")} placeholder="WhatsApp number" className="w-full rounded-md border border-border bg-background px-3 py-2" />
        <div className="flex gap-3">
          <select {...register("gender")} className="flex-1 rounded-md border border-border bg-background px-3 py-2">
            <option value="">Gender</option>
            <option value="male">Male</option>
            <option value="female">Female</option>
            <option value="other">Other</option>
          </select>
          <input type="date" {...register("dob")} className="flex-1 rounded-md border border-border bg-background px-3 py-2" />
        </div>
        {save.isSuccess && <p className="text-sm text-green-600">Saved.</p>}
        {save.isError && <p className="text-sm text-red-500">Could not save.</p>}
        <button disabled={isSubmitting || save.isPending} className="rounded-md bg-foreground px-4 py-2 text-sm font-medium text-background disabled:opacity-50">
          {save.isPending ? "Saving…" : "Save profile"}
        </button>
      </form>
    </div>
  );
}
