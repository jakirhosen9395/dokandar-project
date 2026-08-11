"use client";
import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { useQueryClient } from "@tanstack/react-query";
import { logout } from "@/lib/auth-client";
import { clearRumUser } from "@/lib/rum";
import { useT } from "@/lib/i18n";

export default function LogoutPage() {
  const router = useRouter();
  const qc = useQueryClient();
  const { t } = useT();
  useEffect(() => {
    void (async () => {
      await logout(); // revokes the refresh token (logout everywhere) + clears the cookie
      qc.setQueryData(["me"], null);
      void clearRumUser();
      router.replace("/login");
    })();
  }, [router, qc]);
  return <main className="flex min-h-screen items-center justify-center text-muted-foreground">{t("loggingOut")}</main>;
}
