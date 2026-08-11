import Link from "next/link";
import { RemediationCard } from "@/components/remediation-card";

export default function SellerOrders() {
  return (
    <div className="space-y-4">
      <h1 className="text-xl font-semibold">Orders</h1>
      <RemediationCard
        title="Seller order list unavailable"
        category="C"
        gap="GAP-13 / GAP-1"
        why="Order management for sellers isn’t available yet. Orders placed for your shop can’t be listed until shop setup is enabled for your account."
        owner="Backend — 13-order (seller order list) + 15-api-gateway (shop routing)"
        recommendedFix="Add GET /order/sub-orders?shop_id=… (seller-scoped), and fix the gateway route so /api/v1/seller/* reaches 03-seller's /api/v1/shop/*."
        stillWorks={["Products (create/edit/stock)", "Coupon listing", "Inventory view"]}
        action={<Link href="/seller/products" className="inline-block rounded-md border border-border px-3 py-1.5 text-sm hover:bg-muted">Manage products →</Link>}
      />
    </div>
  );
}
