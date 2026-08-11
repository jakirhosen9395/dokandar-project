"use client";
import { use } from "react";
import Link from "next/link";
import { useQuery } from "@tanstack/react-query";
import { getOrder, getShipmentByOrder } from "@/lib/services/account";
import { formatBDT } from "@/lib/format";

// GAP-8 fix: 17-shipping is customer-reachable by sub-order id. Renders the shipment status when one
// exists; degrades gracefully (no shipment created yet → quiet note).
function ShipmentStatus({ subOrderId }: { subOrderId: string }) {
  const { data, isLoading } = useQuery({
    queryKey: ["shipment", subOrderId],
    queryFn: () => getShipmentByOrder(subOrderId),
    retry: false,
  });
  if (isLoading) return <span className="text-xs text-muted-foreground">tracking…</span>;
  const s = data as Record<string, unknown> | null;
  if (!s || s.error) return <span className="text-xs text-muted-foreground">no shipment yet</span>;
  return (
    <span className="text-xs">
      🚚 {String(s.status ?? s.state ?? "in transit")}
      {s.tracking_code ? ` · ${String(s.tracking_code)}` : ""}
      {s.courier ? ` · ${String(s.courier)}` : ""}
    </span>
  );
}

export default function OrderDetail({ params }: { params: Promise<{ orderId: string }> }) {
  const { orderId } = use(params);
  const { data, isLoading } = useQuery({ queryKey: ["order", orderId], queryFn: () => getOrder(orderId) });

  if (isLoading) return <div className="h-40 animate-pulse rounded-lg bg-muted" />;
  const o = data as Record<string, unknown> | null;
  if (!o) return <p className="text-muted-foreground">Order not found. <Link href="/account/orders" className="underline">Back to orders</Link></p>;

  const subOrders = (o.sub_orders ?? o.subOrders ?? []) as Record<string, unknown>[];

  return (
    <div className="space-y-4">
      <Link href="/account/orders" className="text-sm text-muted-foreground hover:underline">← Orders</Link>
      <h1 className="text-xl font-semibold">Order #{String(o.id ?? orderId).slice(0, 8)}</h1>
      <div className="rounded-lg border border-border p-4 text-sm">
        <div>Status: <span className="font-medium">{String(o.status ?? o.state ?? "—")}</span></div>
        {o.grand_total_minor != null && <div>Total: <span className="font-medium">{formatBDT(o.grand_total_minor as number)}</span></div>}
        {o.created_at ? <div className="text-muted-foreground">Placed: {String(o.created_at)}</div> : null}
      </div>
      {subOrders.length > 0 ? (
        <section>
          <h2 className="mb-2 font-medium">Sub-orders &amp; shipping (one per shop)</h2>
          <ul className="divide-y divide-border rounded-lg border border-border text-sm">
            {subOrders.map((s, i) => {
              const sid = String(s.id ?? i);
              return (
                <li key={sid} className="flex items-center justify-between p-3">
                  <span>#{sid.slice(0, 8)} <span className="text-muted-foreground">· {String(s.status ?? s.state ?? "")}</span></span>
                  <ShipmentStatus subOrderId={sid} />
                </li>
              );
            })}
          </ul>
        </section>
      ) : (
        <p className="text-sm text-muted-foreground">No sub-orders on this order.</p>
      )}
    </div>
  );
}
