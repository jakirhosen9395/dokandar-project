"use client";
import { useState, type FormEvent } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { useQueryClient } from "@tanstack/react-query";
import { requestOtp, verifyOtp } from "@/lib/auth-client";
import { setRumUser } from "@/lib/rum";
import { useT } from "@/lib/i18n";

export function VerifyForm() {
  const router = useRouter();
  const qc = useQueryClient();
  const sp = useSearchParams();
  const { t, locale } = useT();
  const phone = sp.get("phone") || "";
  const mode = (sp.get("mode") as "login" | "signup") || "login";
  const next = sp.get("next") || "/account";
  const name = sp.get("name") || undefined;
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setErr(null);
    const s = await verifyOtp({ mode, phone, code: code.trim(), name, lang: locale });
    setBusy(false);
    if (!s) {
      setErr(t("invalid"));
      return;
    }
    qc.setQueryData(["me"], s.user); // seed server-state cache (no duplicate fetch)
    void setRumUser({ id: s.user.id, role: s.user.role, locale: s.user.lang });
    router.replace(next);
  }

  return (
    <div className="mx-auto flex min-h-screen max-w-sm flex-col justify-center p-6">
      <h2 className="mb-1 text-lg font-semibold">{t("verify")}</h2>
      <p className="mb-4 text-sm text-muted-foreground">
        {t("otpSent")} <span className="font-medium">{phone}</span>
      </p>
      <form onSubmit={submit} className="space-y-3">
        <input value={code} onChange={(e) => setCode(e.target.value)} inputMode="numeric" autoComplete="one-time-code" placeholder={t("code")} required className="w-full rounded-md border border-border bg-background px-3 py-2 tracking-[0.3em] outline-none focus:ring-2 focus:ring-ring" />
        {err && <p className="text-sm text-red-500">{err}</p>}
        <button disabled={busy} className="w-full rounded-md bg-foreground px-3 py-2 font-medium text-background disabled:opacity-50">
          {busy ? "…" : t("verify")}
        </button>
      </form>
      <button type="button" onClick={() => requestOtp(phone, mode)} className="mt-4 text-sm text-muted-foreground hover:underline">
        {t("resend")}
      </button>
    </div>
  );
}
