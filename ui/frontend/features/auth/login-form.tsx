"use client";
import { useState, type FormEvent } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { requestOtp } from "@/lib/auth-client";
import { useT } from "@/lib/i18n";

export function LoginForm() {
  const router = useRouter();
  const next = useSearchParams().get("next") || "/account";
  const { t, locale, setLocale } = useT();
  const [mode, setMode] = useState<"login" | "signup">("login");
  const [phone, setPhone] = useState("");
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setErr(null);
    const ok = await requestOtp(phone.trim(), mode);
    setBusy(false);
    if (!ok) {
      setErr("Could not send a code. Check the number.");
      return;
    }
    const p = new URLSearchParams({ phone: phone.trim(), mode, next });
    if (mode === "signup" && name) p.set("name", name.trim());
    router.push(`/verify?${p.toString()}`);
  }

  return (
    <div className="mx-auto flex min-h-screen max-w-sm flex-col justify-center p-6">
      <div className="mb-6 flex items-center justify-between">
        <h1 className="text-2xl font-bold">DOKANDAR</h1>
        <button type="button" onClick={() => setLocale(locale === "en" ? "bn" : "en")} className="text-sm text-muted-foreground hover:underline">
          {locale === "en" ? "বাংলা" : "EN"}
        </button>
      </div>
      <h2 className="mb-4 text-lg font-semibold">{mode === "login" ? t("login") : t("signup")}</h2>
      <form onSubmit={submit} className="space-y-3">
        <input value={phone} onChange={(e) => setPhone(e.target.value)} inputMode="tel" autoComplete="tel" placeholder={t("phone")} required className="w-full rounded-md border border-border bg-background px-3 py-2 outline-none focus:ring-2 focus:ring-ring" />
        {mode === "signup" && (
          <input value={name} onChange={(e) => setName(e.target.value)} placeholder={t("name")} required className="w-full rounded-md border border-border bg-background px-3 py-2 outline-none focus:ring-2 focus:ring-ring" />
        )}
        {err && <p className="text-sm text-red-500">{err}</p>}
        <button disabled={busy} className="w-full rounded-md bg-foreground px-3 py-2 font-medium text-background disabled:opacity-50">
          {busy ? "…" : t("sendCode")}
        </button>
      </form>
      <button type="button" onClick={() => setMode(mode === "login" ? "signup" : "login")} className="mt-4 text-sm text-muted-foreground hover:underline">
        {mode === "login" ? t("noAccount") : t("haveAccount")}
      </button>
    </div>
  );
}
