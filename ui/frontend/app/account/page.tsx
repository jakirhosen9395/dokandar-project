"use client";
import Link from "next/link";
import { useQuery } from "@tanstack/react-query";
import { useAuth } from "@/hooks/use-auth";
import { getAddresses, getInbox, getOrders, getWallet, getWishlist } from "@/lib/services/account";
import { formatBDT } from "@/lib/format";

function Stat({ title, value, href }: { title: string; value: string; href: string }) {
  return (
    <Link href={href} className="rounded-lg border border-border p-4 hover:bg-muted">
      <div className="text-sm text-muted-foreground">{title}</div>
      <div className="mt-1 text-xl font-semibold">{value}</div>
    </Link>
  );
}

export default function Dashboard() {
  const { user } = useAuth();
  const orders = useQuery({ queryKey: ["orders"], queryFn: getOrders });
  const wallet = useQuery({ queryKey: ["wallet"], queryFn: getWallet });
  const addrs = useQuery({ queryKey: ["addresses"], queryFn: getAddresses });
  const inbox = useQuery({ queryKey: ["inbox", 1], queryFn: () => getInbox(1, 10) });
  const wish = useQuery({ queryKey: ["wishlist"], queryFn: getWishlist });

  const orderList = (orders.data?.orders ?? []) as Record<string, unknown>[];
  const unread = (inbox.data?.items ?? []).filter((n) => !n.read && !n.read_at).length;

  return (
    <div className="space-y-6">
      <h1 className="text-xl font-semibold">Hi{user?.name ? `, ${user.name.split(" ")[0]}` : ""} 👋</h1>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        <Stat title="Orders" value={String(orderList.length)} href="/account/orders" />
        <Stat title="Wallet" value={wallet.data ? formatBDT(wallet.data.available_minor ?? wallet.data.balance_minor) : "…"} href="/account/wallet" />
        <Stat title="Addresses" value={String((addrs.data?.items ?? []).length)} href="/account/addresses" />
        <Stat title="Unread" value={String(unread)} href="/account/notifications" />
        <Stat title="Wishlist" value={String((wish.data?.items ?? []).length)} href="/wishlist" />
        <Stat title="Reviews" value="View" href="/account/reviews" />
      </div>
      <section>
        <h2 className="mb-2 font-medium">Recent orders</h2>
        {orders.isLoading ? (
          <div className="h-20 animate-pulse rounded-lg bg-muted" />
        ) : orderList.length === 0 ? (
          <p className="text-sm text-muted-foreground">No orders yet. <Link href="/search" className="underline">Start shopping</Link>.</p>
        ) : (
          <ul className="divide-y divide-border rounded-lg border border-border text-sm">
            {orderList.slice(0, 5).map((o, i) => {
              const id = String(o.id ?? o.order_id ?? i);
              return (
                <li key={id} className="flex justify-between p-3">
                  <Link href={`/account/orders/${id}`} className="hover:underline">#{id.slice(0, 8)}</Link>
                  <span className="text-muted-foreground">{String(o.status ?? o.state ?? "")}</span>
                </li>
              );
            })}
          </ul>
        )}
      </section>
    </div>
  );
}
