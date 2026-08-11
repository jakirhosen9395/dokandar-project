using Prometheus;

namespace Coupon.Observability;

public static class Metrics
{
    public const string Svc = "07-coupon";
    public static readonly Counter HttpRequests = Prometheus.Metrics.CreateCounter(
        "http_requests_total", "HTTP requests", new CounterConfiguration { LabelNames = new[] { "method", "route", "status" } });
    public static readonly Histogram HttpDuration = Prometheus.Metrics.CreateHistogram(
        "http_request_duration_seconds", "HTTP latency", new HistogramConfiguration { LabelNames = new[] { "method", "route" } });
    public static readonly Counter CouponValidations = Prometheus.Metrics.CreateCounter(
        "coupon_validations_total", "ValidateCoupon outcomes", new CounterConfiguration { LabelNames = new[] { "service", "result" } });
    public static readonly Histogram CouponValidationMs = Prometheus.Metrics.CreateHistogram(
        "coupon_validation_ms", "ValidateCoupon latency (ms)", new HistogramConfiguration { LabelNames = new[] { "service" }, Buckets = new[] { 1, 5, 10, 25, 50, 100, 250, 500.0 } });
    public static readonly Counter CouponDrafts = Prometheus.Metrics.CreateCounter(
        "coupon_drafts_total", "coupons drafted", new CounterConfiguration { LabelNames = new[] { "service", "scope" } });
    public static readonly Counter CouponApprovals = Prometheus.Metrics.CreateCounter(
        "coupon_approvals_total", "four-eyes approvals", new CounterConfiguration { LabelNames = new[] { "service" } });
    public static readonly Counter CouponRevocations = Prometheus.Metrics.CreateCounter(
        "coupon_revocations_total", "coupon revocations", new CounterConfiguration { LabelNames = new[] { "service" } });
    public static readonly Counter CouponRedemptions = Prometheus.Metrics.CreateCounter(
        "coupon_redemptions_total", "redemptions recorded", new CounterConfiguration { LabelNames = new[] { "service" } });
    public static readonly Counter OutboxPublished = Prometheus.Metrics.CreateCounter(
        "coupon_outbox_published_total", "outbox rows published to Kafka", new CounterConfiguration { LabelNames = new[] { "service" } });
    public static readonly Gauge OutboxPending = Prometheus.Metrics.CreateGauge(
        "coupon_outbox_pending", "unsent outbox rows", new GaugeConfiguration { LabelNames = new[] { "service" } });
}
