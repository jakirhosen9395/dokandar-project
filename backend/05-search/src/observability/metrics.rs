//! Prometheus exposition. RED metrics on the HTTP surface + projection gauges.
use once_cell::sync::Lazy;
use prometheus::{Encoder, HistogramVec, IntCounterVec, IntGaugeVec, Registry, TextEncoder};

pub static REGISTRY: Lazy<Registry> = Lazy::new(Registry::new);

pub static HTTP_REQUESTS: Lazy<IntCounterVec> = Lazy::new(|| {
    let c = IntCounterVec::new(
        prometheus::opts!("http_requests_total", "HTTP requests by method/route/status"),
        &["method", "route", "status"],
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

pub static PROJECTION_LAG: Lazy<IntGaugeVec> = Lazy::new(|| {
    let g = IntGaugeVec::new(
        prometheus::opts!("search_projection_lag_messages", "Kafka consumer lag (messages) per projector topic"),
        &["topic"],
    ).unwrap();
    REGISTRY.register(Box::new(g.clone())).ok();
    g
});

pub static VIEW_ROWS: Lazy<IntGaugeVec> = Lazy::new(|| {
    let g = IntGaugeVec::new(
        prometheus::opts!("search_view_rows", "Row count per *_view projection table"),
        &["view"],
    ).unwrap();
    REGISTRY.register(Box::new(g.clone())).ok();
    g
});

pub fn observe(method: &str, route: &str, status: u16, secs: f64) {
    HTTP_REQUESTS.with_label_values(&[method, route, &status.to_string()]).inc();
    HTTP_DURATION.with_label_values(&[method, route]).observe(secs);
}

pub fn render() -> String {
    // touch lazies so they always appear
    Lazy::force(&HTTP_REQUESTS); Lazy::force(&HTTP_DURATION);
    Lazy::force(&PROJECTION_LAG); Lazy::force(&VIEW_ROWS);
    let mut buf = Vec::new();
    let enc = TextEncoder::new();
    enc.encode(&REGISTRY.gather(), &mut buf).ok();
    String::from_utf8(buf).unwrap_or_default()
}
