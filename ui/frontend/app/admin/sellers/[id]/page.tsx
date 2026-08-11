import { RemediationCard } from "@/components/remediation-card";

export default function AdminSellerDetail() {
  return (
    <div className="space-y-4">
      <h1 className="text-xl font-semibold">Seller</h1>
      <RemediationCard
        title="Seller detail unavailable"
        why="Shop detail and moderation aren’t available yet — the shop service isn’t reachable through the API gateway."
        category="C"
        gap="GAP-1"
        owner="Backend — API gateway route prefix / shop service"
        recommendedFix="Align the gateway route so the seller prefix reaches the shop service."
      />
    </div>
  );
}
