//! Actix HTTP surface: shared AppState, the OUTERMOST middleware (request-id honour-or-mint +
//! APM server transaction + RED metrics), the 7 business routes + the ops contract, and bare-404.
pub mod handlers;
pub mod openapi;
pub mod ops;

use crate::config::Config;
use crate::observability::{logging, metrics, otel};
use actix_web::dev::{Service, ServiceRequest, ServiceResponse, Transform};
use actix_web::http::header::{HeaderName, HeaderValue};
use actix_web::{web, App, Error, HttpServer};
use futures::future::{ok, LocalBoxFuture, Ready};
use opentelemetry::trace::FutureExt;
use sqlx::postgres::PgPool;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Instant;

/// Shared application state (HTTP handlers only — background tasks own their own clones).
pub struct AppState {
    pub cfg: Config,
    pub pool: Option<PgPool>,
    pub s3: Option<crate::s3::S3>,
    pub http: reqwest::Client,
    pub boot: Instant,
}

/// Build + bind + run the Actix server. Background tasks are spawned by main before this.
pub async fn serve(state: Arc<AppState>) -> std::io::Result<()> {
    let port = state.cfg.service_port;
    let data = web::Data::from(state);
    logging::warn("media.http", &format!("http server listening on :{port}"));
    HttpServer::new(move || {
        App::new()
            .app_data(data.clone())
            // ── ops contract (no auth) ──
            .route("/ready", web::get().to(ops::ready))
            .route("/health", web::get().to(ops::health))
            .route("/data", web::get().to(ops::data))
            .route("/metrics", web::get().to(ops::metrics_ep))
            .route("/openapi.json", web::get().to(ops::openapi_json))
            .route("/docs", web::get().to(ops::docs))
            // ── business API (all AuthUser-guarded) ──
            .route("/api/v1/media/upload-url", web::post().to(handlers::upload_url))
            .route("/api/v1/media/{id}/complete", web::post().to(handlers::complete))
            .route("/api/v1/media/{id}/signed-url", web::get().to(handlers::signed_url))
            .route("/api/v1/media/{id}/grants", web::post().to(handlers::grant))
            .route("/api/v1/media/{id}", web::get().to(handlers::get_one))
            .route("/api/v1/media/{id}", web::delete().to(handlers::delete_one))
            .route("/api/v1/media", web::get().to(handlers::list_mine))
            // bare-404 on every unmapped path (empty body, no content-type)
            .default_service(web::route().to(ops::bare_404))
            // LAST .wrap() = OUTERMOST. The Observability transform does request-id + APM + metrics.
            .wrap(Observability)
    })
    .bind(("0.0.0.0", port))?
    .workers(2)
    .run()
    .await
}

// ── OUTERMOST middleware: honour-or-mint x-request-id + APM server span + RED metrics ──
pub struct Observability;

impl<S, B> Transform<S, ServiceRequest> for Observability
where
    S: Service<ServiceRequest, Response = ServiceResponse<B>, Error = Error> + 'static,
    B: 'static,
{
    type Response = ServiceResponse<B>;
    type Error = Error;
    type InitError = ();
    type Transform = ObservabilityMw<S>;
    type Future = Ready<Result<Self::Transform, ()>>;
    fn new_transform(&self, service: S) -> Self::Future {
        ok(ObservabilityMw { service: Rc::new(service) })
    }
}

pub struct ObservabilityMw<S> {
    service: Rc<S>,
}

impl<S, B> Service<ServiceRequest> for ObservabilityMw<S>
where
    S: Service<ServiceRequest, Response = ServiceResponse<B>, Error = Error> + 'static,
    B: 'static,
{
    type Response = ServiceResponse<B>;
    type Error = Error;
    type Future = LocalBoxFuture<'static, Result<Self::Response, Error>>;

    fn poll_ready(
        &self,
        ctx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Result<(), Self::Error>> {
        self.service.poll_ready(ctx)
    }

    fn call(&self, req: ServiceRequest) -> Self::Future {
        let svc = self.service.clone();
        let method = req.method().as_str().to_string();
        let path = req.path().to_string();
        // closed-set route label: the matched pattern, or "<unmatched>" for unmapped paths
        // (a raw path would make http_requests_total labels unbounded — contract forbids it).
        let route = req
            .match_pattern()
            .unwrap_or_else(|| "<unmatched>".to_string());
        // honour-or-mint request id
        let rid = req
            .headers()
            .get("x-request-id")
            .and_then(|v| v.to_str().ok())
            .map(|s| s.to_string())
            .unwrap_or_else(|| uuid::Uuid::new_v4().simple().to_string());

        Box::pin(async move {
            let start = Instant::now();
            let cx = otel::server_context(&method, &route, &path);
            let mut resp = match cx.clone() {
                Some(c) => svc.call(req).with_context(c).await?,
                None => svc.call(req).await?,
            };
            let status = resp.status().as_u16();
            if let Some(c) = &cx {
                otel::end_server(c, status);
            }
            let secs = start.elapsed().as_secs_f64();
            // exclude /ready + /metrics from access log + RED (per contract).
            if route != "/metrics" && route != "/ready" {
                metrics::observe(&method, &route, status, secs);
                let tid = cx
                    .as_ref()
                    .and_then(|_| otel::current_ids().map(|(t, _)| t));
                logging::access(&method, &path, &route, status, secs * 1000.0, &rid, tid.as_deref());
            }
            // echo the request id back
            if let (Ok(name), Ok(val)) =
                (HeaderName::try_from("x-request-id"), HeaderValue::from_str(&rid))
            {
                resp.headers_mut().insert(name, val);
            }
            Ok(resp)
        })
    }
}
