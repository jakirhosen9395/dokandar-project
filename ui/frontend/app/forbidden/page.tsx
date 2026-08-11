"use client";
import Link from "next/link";
import { useT } from "@/lib/i18n";

export default function ForbiddenPage() {
  const { t } = useT();
  return (
    <main className="mx-auto flex min-h-screen max-w-md flex-col items-center justify-center p-6 text-center">
      <h1 className="text-3xl font-bold">{t("forbidden")}</h1>
      <p className="mt-2 text-muted-foreground">{t("forbiddenMsg")}</p>
      <Link href="/" className="mt-6 rounded border border-border px-3 py-1.5 text-sm hover:bg-muted">
        {t("backHome")}
      </Link>
    </main>
  );
}
