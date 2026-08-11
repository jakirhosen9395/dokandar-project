import { RemediationCard } from "@/components/remediation-card";

export default function AdminNotifications() {
  return (
    <div className="space-y-4">
      <h1 className="text-xl font-semibold">Notifications</h1>
      <RemediationCard
        title="Platform notification monitoring unavailable"
        category="B"
        gap="GAP-21"
        why="Platform-wide notification monitoring isn’t available yet — only each user’s own inbox is exposed. Delivery health is observable via the metrics and log sinks in System."
        owner="Backend — notification service (admin monitoring API)"
        recommendedFix="Add an admin delivery-monitoring endpoint (status, channel, failures) with per-channel counters."
        stillWorks={["Each user's own inbox (Customer portal)", "Service health + observability model in System"]}
      />
    </div>
  );
}
