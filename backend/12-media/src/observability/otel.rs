//! APM tracing: OpenTelemetry SDK → OTLP/HTTP → Elastic APM Server (:8200).
//! Each HTTP request is a SERVER transaction; PG/S3/Kafka/gRPC calls become CLIENT exit
//! spans nested under it (drives Dependencies + Service Map). Ported verbatim from 05-search
//! (renamed apm_otlp→otel, search→media). APM must be the OUTERMOST wrapper.
use crate::config::Config;
use opentelemetry::global::{self, BoxedSpan};
use opentelemetry::trace::{Span, SpanKind, Status, TraceContextExt, Tracer};
use opentelemetry::{Context, KeyValue};
use opentelemetry_otlp::{SpanExporter, WithExportConfig, WithHttpConfig};
use opentelemetry_sdk::trace::TracerProvider as SdkTracerProvider;
use opentelemetry_sdk::metrics::{PeriodicReader, SdkMeterProvider};
use opentelemetry_otlp::MetricExporter;
use opentelemetry_sdk::Resource;
use std::collections::HashMap;
use std::sync::OnceLock;

static ENABLED: OnceLock<bool> = OnceLock::new();
static PROVIDER: OnceLock<SdkTracerProvider> = OnceLock::new();
static METERP: OnceLock<SdkMeterProvider> = OnceLock::new();
static MEM_GAUGE: OnceLock<opentelemetry::metrics::ObservableGauge<u64>> = OnceLock::new();

fn on() -> bool { *ENABLED.get().unwrap_or(&false) }

pub fn init(cfg: &Config) {
    if cfg.otlp_endpoint.is_empty() { eprintln!("APM: OTEL endpoint empty — tracing disabled"); ENABLED.set(false).ok(); return; }
    let mut headers = HashMap::new();
    if !cfg.apm_secret_token.is_empty() { headers.insert("Authorization".to_string(), format!("Bearer {}", cfg.apm_secret_token)); }
    let endpoint = format!("{}/v1/traces", cfg.otlp_endpoint.trim_end_matches('/'));
    let exporter = match SpanExporter::builder().with_http().with_endpoint(endpoint).with_headers(headers).build() {
        Ok(e) => e, Err(e) => { eprintln!("APM: exporter build failed: {e:?}"); ENABLED.set(false).ok(); return; }
    };
    let host = std::fs::read_to_string("/etc/hostname").map(|s| s.trim().to_string()).unwrap_or_else(|_| "unknown".into());
    let resource = Resource::new(vec![
        KeyValue::new("service.name", cfg.apm_service_name.clone()),
        KeyValue::new("service.version", cfg.code_version.clone()),
        KeyValue::new("deployment.environment", cfg.app_env.clone()),
        KeyValue::new("host.name", host.clone()),
        KeyValue::new("host.hostname", host.clone()),
        KeyValue::new("container.id", host),
        KeyValue::new("telemetry.sdk.language", "rust"),
        KeyValue::new("service.framework.name", "actix-web"),
    ]);
    let provider = SdkTracerProvider::builder()
        .with_batch_exporter(exporter, opentelemetry_sdk::runtime::Tokio)
        .with_resource(resource).build();
    global::set_tracer_provider(provider.clone());
    PROVIDER.set(provider).ok();
    ENABLED.set(true).ok();
    init_metrics(cfg);
}

/// Begin an HTTP SERVER transaction; returns a Context to attach to the request future
/// so exit spans created during handling nest under it.
pub fn server_context(method: &str, route: &str, path: &str) -> Option<Context> {
    if !on() { return None; }
    let tracer = global::tracer("dokandar-media");
    let mut span = tracer.span_builder(format!("{} {}", method, route)).with_kind(SpanKind::Server).start(&tracer);
    span.set_attribute(KeyValue::new("http.request.method", method.to_string()));
    span.set_attribute(KeyValue::new("url.path", path.to_string()));
    span.set_attribute(KeyValue::new("http.route", route.to_string()));
    Some(Context::current_with_span(span))
}

pub fn end_server(cx: &Context, status: u16) {
    let s = cx.span();
    s.set_attribute(KeyValue::new("http.response.status_code", status as i64));
    if status >= 500 { s.set_status(Status::error("server_error")); } else { s.set_status(Status::Ok); }
    s.end();
}

/// A dependency (exit) span — `system` (postgresql/s3/kafka/grpc) drives the
/// Elastic Service-Map destination node. Parent = the current context's span.
pub fn dep_span(name: &str, system: &str, statement: &str) -> Option<BoxedSpan> {
    if !on() { return None; }
    let tracer = global::tracer("dokandar-media");
    let mut span = tracer.span_builder(name.to_string()).with_kind(SpanKind::Client).start(&tracer);
    span.set_attribute(KeyValue::new("db.system", system.to_string()));
    span.set_attribute(KeyValue::new("peer.service", system.to_string()));
    if !statement.is_empty() {
        let stmt: String = statement.split_whitespace().collect::<Vec<_>>().join(" ").chars().take(200).collect();
        span.set_attribute(KeyValue::new("db.statement", stmt));
    }
    Some(span)
}

pub fn end_dep(span: Option<BoxedSpan>) { if let Some(mut s) = span { s.end(); } }

/// A messaging consume transaction for a RabbitMQ worker (drives Service-Map edge).
pub fn consume_context(queue: &str) -> Option<Context> {
    if !on() { return None; }
    let tracer = global::tracer("dokandar-media");
    let mut span = tracer.span_builder(format!("{} receive", queue)).with_kind(SpanKind::Consumer).start(&tracer);
    span.set_attribute(KeyValue::new("messaging.system", "rabbitmq".to_string()));
    span.set_attribute(KeyValue::new("messaging.destination.name", queue.to_string()));
    Some(Context::current_with_span(span))
}
pub fn end_context(cx: &Context) { cx.span().end(); }


/// OTLP metrics → Elastic APM "Metrics"/Instances tabs (the `app` metricset auth has).
fn init_metrics(cfg: &Config) {
    let mut headers = HashMap::new();
    if !cfg.apm_secret_token.is_empty() { headers.insert("Authorization".to_string(), format!("Bearer {}", cfg.apm_secret_token)); }
    let endpoint = format!("{}/v1/metrics", cfg.otlp_endpoint.trim_end_matches('/'));
    let exporter = match MetricExporter::builder().with_http().with_endpoint(endpoint).with_headers(headers).build() {
        Ok(e) => e, Err(e) => { eprintln!("APM: metric exporter build failed: {e:?}"); return; }
    };
    let reader = PeriodicReader::builder(exporter, opentelemetry_sdk::runtime::Tokio)
        .with_interval(std::time::Duration::from_secs(15)).build();
    let host = std::fs::read_to_string("/etc/hostname").map(|s| s.trim().to_string()).unwrap_or_default();
    let resource = Resource::new(vec![
        KeyValue::new("service.name", cfg.apm_service_name.clone()),
        KeyValue::new("service.version", cfg.code_version.clone()),
        KeyValue::new("deployment.environment", cfg.app_env.clone()),
        KeyValue::new("host.name", host.clone()),
        KeyValue::new("container.id", host),
    ]);
    let provider = SdkMeterProvider::builder().with_reader(reader).with_resource(resource).build();
    global::set_meter_provider(provider.clone());
    let meter = global::meter("dokandar-media");
    let gauge = meter.u64_observable_gauge("process.memory.usage").with_unit("By")
        .with_callback(|o| {
            if let Ok(s) = std::fs::read_to_string("/proc/self/statm") {
                if let Some(rss) = s.split_whitespace().nth(1).and_then(|x| x.parse::<u64>().ok()) {
                    o.observe(rss.saturating_mul(4096), &[]);
                }
            }
        }).build();
    MEM_GAUGE.set(gauge).ok();
    METERP.set(provider).ok();
}

/// (trace_id, span_id) of the current context, for log↔trace correlation.
pub fn current_ids() -> Option<(String, String)> {
    if !on() { return None; }
    let cx = Context::current();
    let sc = cx.span().span_context().clone();
    if sc.is_valid() { Some((format!("{}", sc.trace_id()), format!("{}", sc.span_id()))) } else { None }
}
