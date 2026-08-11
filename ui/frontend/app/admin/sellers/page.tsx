import Link from "next/link";
import { RemediationCard } from "@/components/remediation-card";

export default function AdminSellers() {
  return (
    <div className="space-y-4">
      <h1 className="text-xl font-semibold">Sellers</h1>
      <RemediationCard
        title="Seller management unavailable"
        category="C"
        gap="GAP-1"
        why="Shop management isn’t available yet — the shop service isn’t reachable through the API gateway, so shops can’t be listed or moderated here."
        owner="Backend — API gateway route prefix / shop service"
        recommendedFix="Align the gateway route so the seller prefix reaches the shop service. This single fix unblocks shop listing, moderation, seller analytics, publishing and seller coupons."
        stillWorks={["Seller identity & KYC moderation (Users & KYC)", "Platform KPIs, payments, payouts, risk rules"]}
        action={<Link href="/admin/users" className="inline-block rounded-md border border-border px-3 py-1.5 text-sm hover:bg-muted">Seller KYC queue →</Link>}
      />
    </div>
  );
}
