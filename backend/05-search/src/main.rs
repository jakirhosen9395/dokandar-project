//! DOKANDAR 05-search — Rust / Axum CQRS read projection.
mod auth;
mod config;
mod db;
mod observability;
mod ops;
mod openapi;
mod projectors;
mod search;

use axum::{
    extract::{MatchedPath, Request, State},
    http::StatusCode,
    middleware::{self, Next},
    response::{Html, Response},
    routing::{get, post},
    Router,
};
use observability::{apm_otlp, logging, metrics};
use opentelemetry::trace::{FutureExt, TraceContextExt};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Instant;

#[tokio::main]
async fn main() {
    let cfg = config::Config::from_env();
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::new(std::env::var("RUST_LOG").unwrap_or_else(|_| "info".into())))
        .with_target(false).init();

    logging::init(&cfg);
    apm_otlp::init(&cfg);
    logging::info("search.boot", &format!(
        "starting {} code_version={} port={} tenant={} env={}",
        cfg.service_name, cfg.code_version, cfg.service_port, cfg.tenant, cfg.app_env));

    let pool = match db::ensure_db_and_pool(&cfg).await {
        Ok(p) => { logging::info("search.boot", "postgres pool ready; migrations applied"); Some(p) }
        Err(e) => { logging::error("search.boot", &format!("postgres init failed (/ready will be 503): {e}")); None }
    };

    if let Some(p) = &pool {
        projectors::start_all(&cfg, p.clone());
        logging::info("search.boot", "kafka projectors started (product/shop/category/order)");
    }

    let http = reqwest::Client::builder().danger_accept_invalid_certs(true).build().expect("reqwest client");
    let state = Arc::new(ops::AppState { cfg: cfg.clone(), pool, http, boot: Instant::now() });

    let app = Router::new()
        .route("/ready", get(ops::ready))
        .route("/health", get(ops::health))
        .route("/data", get(ops::data))
        .route("/metrics", get(ops::metrics_ep))
        .route("/openapi.json", get(openapi_json))
        .route("/docs", get(docs))
        .route("/api/v1/search/products", get(search::products))
        .route("/api/v1/search/autocomplete", get(search::autocomplete))
        .route("/api/v1/search/shops", get(search::shops))
        .route("/api/v1/search/trending", get(search::trending))
        .route("/api/v1/search/categories/tree", get(search::categories_tree))
        .route("/api/v1/search/admin/reindex", post(search::admin_reindex))
        .fallback(bare_404)
        .with_state(state)
        .layer(middleware::from_fn(access_log_mw));

    let addr = SocketAddr::from(([0, 0, 0, 0], cfg.service_port));
    let listener = tokio::net::TcpListener::bind(addr).await.expect("bind");
    logging::warn("search.boot", &format!("http server listening on :{}", cfg.service_port));
    axum::serve(listener, app).await.expect("serve");
}

async fn openapi_json(State(st): State<Arc<ops::AppState>>) -> Response { ops::pretty(StatusCode::OK, openapi::spec(&st.cfg)) }
async fn docs() -> Html<&'static str> { Html(openapi::SWAGGER_HTML) }
async fn bare_404() -> Response { Response::builder().status(StatusCode::NOT_FOUND).body(axum::body::Body::empty()).unwrap() }

async fn access_log_mw(req: Request, next: Next) -> Response {
    let method = req.method().as_str().to_string();
    let path = req.uri().path().to_string();
    let route = req.extensions().get::<MatchedPath>().map(|m| m.as_str().to_string()).unwrap_or_else(|| path.clone());
    let rid = req.headers().get("x-request-id").and_then(|v| v.to_str().ok())
        .map(|s| s.to_string()).unwrap_or_else(|| uuid::Uuid::new_v4().simple().to_string());
    let cx = apm_otlp::server_context(&method, &route, &path);
    let trace_id = cx.as_ref().and_then(|c| { let sc = c.span().span_context().clone(); if sc.is_valid() { Some(format!("{}", sc.trace_id())) } else { None } });
    let start = Instant::now();
    let mut resp = match cx.clone() {
        Some(c) => next.run(req).with_context(c).await,
        None => next.run(req).await,
    };
    let secs = start.elapsed().as_secs_f64();
    let status = resp.status().as_u16();
    if let Some(c) = &cx { apm_otlp::end_server(c, status); }
    if route != "/metrics" && route != "/ready" {
        metrics::observe(&method, &route, status, secs);
        logging::access(&method, &path, &route, status, secs * 1000.0, &rid, trace_id.as_deref());
    }
    if let Ok(hv) = rid.parse() { resp.headers_mut().insert("x-request-id", hv); }
    resp
}
