import { RemediationCard } from "@/components/remediation-card";

export default function SellerAnalytics() {
  return (
    <div className="space-y-4">
      <h1 className="text-xl font-semibold">Analytics</h1>
      <RemediationCard
        title="Seller analytics unavailable"
        category="B"
        gap="reporting"
        why="Your sales analytics will appear here once shop setup is enabled. We don’t show estimated or sample figures — only real data from your shop."
        owner="Backend — API gateway shop routing → reporting (shop KPIs)"
        recommendedFix="Enable shop routing through the gateway; seller analytics then reads per-shop KPIs from reporting. No fabricated charts are shown meanwhile."
        stillWorks={["Platform-level KPIs are visible to admins in the Admin console"]}
      />
    </div>
  );
}
