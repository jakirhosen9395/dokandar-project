import { Suspense } from "react";
import { VerifyForm } from "@/features/auth/verify-form";

export const dynamic = "force-dynamic";

export default function VerifyPage() {
  return (
    <Suspense fallback={null}>
      <VerifyForm />
    </Suspense>
  );
}
