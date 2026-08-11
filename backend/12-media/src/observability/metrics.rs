//! Prometheus exposition. RED metrics on the HTTP surface + 12-media service counters.
//! Closed-set labels only (no UUIDs / path-params). Every service exposes <svc>_outbox_pending.
use once_cell::sync::Lazy;
use prometheus::{Encoder, HistogramVec, IntCounter, IntCounterVec, IntGauge, Registry, TextEncoder};

/// Injected as the `service` label on http_requests_total (keeps observe() signature stable).
pub const SERVICE_VAL: &str = "12-media";

pub static REGISTRY: Lazy<Registry> = Lazy::new(Registry::new);

pub static HTTP_REQUESTS: Lazy<IntCounterVec> = Lazy::new(|| {
    let c = IntCounterVec::new(
        prometheus::opts!("http_requests_total", "HTTP requests by service/method/route/status"),
        &["service", "method", "route", "status"],
    ).unwrap();
    REGISTRY.register(Box::new(c.clone())).ok();
    c
});

pub static HTTP_DURATION: Lazy<HistogramVec> = Lazy::new(|| {
    let h = HistogramVec::new(
        prometheus::histogram_opts!("http_request_duration_seconds", "HTTP request latency"),
        &["method", "route"],
    ).unwrap();
    REGISTRY.register(Box::new(h.clone())).ok();
    h
});

// ── 12-media service counters ────────────────────────────────────────────────────────────────
pub static MEDIA_UPLOADS: Lazy<IntCounter> = Lazy::new(|| {
    let c = IntCounter::new("media_uploads_total", "Presigned upload URLs issued (pending objects created)").unwrap();
    REGISTRY.register(Box::new(c.clone())).ok();
    c
});

pub static MEDIA_COMPLETED: Lazy<IntCounter> = Lazy::new(|| {
    let c = IntCounter::new("media_completed_total", "Uploads confirmed via /complete (state→uploaded)").unwrap();
    REGISTRY.register(Box::new(c.clone())).ok();
    c
});

pub static MEDIA_SCANNED: Lazy<IntCounterVec> = Lazy::new(|| {
    let c = IntCounterVec::new(
        prometheus::opts!("media_scanned_total", "AV scans completed by verdict"),
        &["verdict"],   // clean | infected | error
    ).unwrap();
    REGISTRY.register(Box::new(c.clone())).ok();
    c
});

pub static MEDIA_SIGNED_URLS: Lazy<IntCounter> = Lazy::new(|| {
    let c = IntCounter::new("media_signed_urls_total", "Presigned download URLs issued").unwrap();
    REGISTRY.register(Box::new(c.clone())).ok();
    c
});

pub static MEDIA_OUTBOX_PUBLISHED: Lazy<IntCounter> = Lazy::new(|| {
    let c = IntCounter::new("media_outbox_published_total", "Outbox rows successfully published to Kafka").unwrap();
    REGISTRY.register(Box::new(c.clone())).ok();
    c
});

/// MANDATORY fleet gauge — relay lag (outbox rows WHERE sent_at IS NULL).
pub static MEDIA_OUTBOX_PENDING: Lazy<IntGauge> = Lazy::new(|| {
    let g = IntGauge::new("media_outbox_pending", "Outbox rows awaiting Kafka publish (relay lag)").unwrap();
    REGISTRY.register(Box::new(g.clone())).ok();
    g
});

/// RED observation for a finished HTTP request. Injects SERVICE_VAL so the call site stays
/// `observe(method, route, status, secs)`.
pub fn observe(method: &str, route: &str, status: u16, secs: f64) {
    HTTP_REQUESTS.with_label_values(&[SERVICE_VAL, method, route, &status.to_string()]).inc();
    HTTP_DURATION.with_label_values(&[method, route]).observe(secs);
}

pub fn render() -> String {
    // touch lazies so they always appear, even before first increment
    Lazy::force(&HTTP_REQUESTS); Lazy::force(&HTTP_DURATION);
    Lazy::force(&MEDIA_UPLOADS); Lazy::force(&MEDIA_COMPLETED); Lazy::force(&MEDIA_SCANNED);
    Lazy::force(&MEDIA_SIGNED_URLS); Lazy::force(&MEDIA_OUTBOX_PUBLISHED); Lazy::force(&MEDIA_OUTBOX_PENDING);
    let mut buf = Vec::new();
    let enc = TextEncoder::new();
    enc.encode(&REGISTRY.gather(), &mut buf).ok();
    String::from_utf8(buf).unwrap_or_default()
}
