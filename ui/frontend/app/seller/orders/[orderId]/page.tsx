"use client";
import { use } from "react";
import { useQuery } from "@tanstack/react-query";
import { authedFetch } from "@/lib/auth-client";

export default function SellerSubOrder({ params }: { params: Promise<{ orderId: string }> }) {
  const { orderId } = use(params);
  const { data, isLoading } = useQuery({
    queryKey: ["sub-order", orderId],
    queryFn: async () => {
      const r = await authedFetch(`order/sub-orders/${orderId}`);
      return r.ok ? r.json() : null;
    },
  });
  const o = data as Record<string, unknown> | null;

  return (
    <div className="space-y-3">
      <h1 className="text-xl font-semibold">Sub-order #{orderId.slice(0, 8)}</h1>
      {isLoading ? (
        <div className="h-24 animate-pulse rounded bg-muted" />
      ) : !o ? (
        <p className="text-muted-foreground">This sub-order isn’t available — seller fulfilment unlocks once shop setup is enabled.</p>
      ) : (
        <div className="rounded-lg border border-border p-4 text-sm">Status: {String(o.status ?? o.state ?? "—")}</div>
      )}
      <p className="text-xs text-muted-foreground">
        Order status updates unlock once shop setup is enabled for your account.
      </p>
    </div>
  );
}
