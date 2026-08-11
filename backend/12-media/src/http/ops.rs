//! Operational contract: /ready (PG + S3 gated) /health (all deps + observability) /data /metrics
//! /openapi.json /docs, plus the shared pretty-JSON / error-envelope / request-id helpers and the
//! bare-404 default service.
use crate::http::{openapi, AppState};
use crate::observability::{logging, metrics, otel};
use actix_web::{web, HttpRequest, HttpResponse};
use serde_json::{json, Value};
use std::time::Duration;

/// Honour-or-mint x-request-id (read side, for handlers/extractors).
pub fn req_id(req: &HttpRequest) -> String {
    req.headers()
        .get("x-request-id")
        .and_then(|v| v.to_str().ok())
        .map(str::to_string)
        .unwrap_or_else(|| uuid::Uuid::new_v4().simple().to_string())
}

/// Pretty-JSON (indent 2, non-ASCII literal so Bangla stays UTF-8) + trailing newline.
pub fn pretty(code: u16, body: Value) -> HttpResponse {
    let txt = serde_json::to_string_pretty(&body).unwrap_or_default() + "\n";
    HttpResponse::build(actix_web::http::StatusCode::from_u16(code).unwrap_or(actix_web::http::StatusCode::OK))
        .content_type("application/json")
        .body(txt)
}

/// One error envelope. 5xx internals are scrubbed before reaching the client.
pub fn err(code: u16, ecode: &str, msg: &str, rid: &str) -> HttpResponse {
    let shown = if code >= 500 { "internal error" } else { msg };
    pretty(
        code,
        json!({"error": {"code": ecode, "message": shown, "request_id": rid, "details": Value::Null}}),
    )
}

/// Bare-404: status 404, empty body, no content-type, Content-Length: 0.
pub async fn bare_404() -> HttpResponse {
    HttpResponse::NotFound().finish()
}

fn identity(st: &AppState) -> Value {
    json!({
        "service_name": st.cfg.service_name,
        "code_version": st.cfg.code_version,
        "env_version": st.cfg.env_version,
        "tenant": st.cfg.tenant,
        "env": st.cfg.app_env,
        "uptime_seconds": st.boot.elapsed().as_secs(),
    })
}

async fn check_pg(st: &AppState) -> (bool, String) {
    match &st.pool {
        None => (false, "no-pool".into()),
        Some(p) => {
            let sp = otel::dep_span("SELECT 1", "postgresql", "SELECT 1");
            let r = sqlx::query("SELECT 1").execute(p).await;
            otel::end_dep(sp);
            match r {
                Ok(_) => (true, "ok".into()),
                Err(e) => (false, format!("err:{}", short(&e.to_string()))),
            }
        }
    }
}

async fn check_s3(st: &AppState) -> (bool, String) {
    match &st.s3 {
        None => (false, "no-client".into()),
        Some(s) => {
            if s.reachable().await {
                (true, "ok".into())
            } else {
                (false, "unreachable".into())
            }
        }
    }
}

fn check_kafka(boot: &str) -> (bool, String) {
    if boot.is_empty() {
        return (false, "no-bootstrap".into());
    }
    let (h, p) = boot.split(',').next().unwrap_or(boot).rsplit_once(':').unwrap_or((boot, "9092"));
    use std::net::ToSocketAddrs;
    match (h, p.parse::<u16>().unwrap_or(9092))
        .to_socket_addrs()
        .ok()
        .and_then(|mut a| a.next())
    {
        Some(addr) => match std::net::TcpStream::connect_timeout(&addr, Duration::from_secs(2)) {
            Ok(_) => (true, "tcp-ok".into()),
            Err(e) => (false, format!("err:{:?}", e.kind())),
        },
        None => (false, "resolve-failed".into()),
    }
}

async fn check_es(st: &AppState, url: &str, user: &str, pass: &str) -> (bool, String) {
    if url.is_empty() {
        return (false, "url-empty".into());
    }
    let mut req = st
        .http
        .get(format!("{}/_cluster/health", url.trim_end_matches('/')))
        .timeout(Duration::from_secs(2));
    if !user.is_empty() {
        req = req.basic_auth(user, Some(pass));
    }
    let sp = otel::dep_span("GET _cluster/health", "elasticsearch", "");
    let r = req.send().await;
    otel::end_dep(sp);
    match r {
        Ok(r) if r.status().is_success() => (true, "green".into()),
        Ok(r) => (false, format!("http:{}", r.status().as_u16())),
        Err(e) => (false, format!("err:{}", short(&e.to_string()))),
    }
}

fn short(s: &str) -> String {
    s.chars().take(48).collect()
}

/// GET /ready — gate Postgres AND S3 (cannot presign without the object store).
pub async fn ready(st: web::Data<AppState>) -> HttpResponse {
    let (pg, pgd) = check_pg(&st).await;
    let (s3, s3d) = check_s3(&st).await;
    let ok = pg && s3;
    pretty(
        if ok { 200 } else { 503 },
        json!({
            "status": if ok { "ready" } else { "not_ready" },
            "identity": identity(&st),
            "dependencies": [
                {"name":"postgres","reachable":pg,"detail":pgd},
                {"name":"s3","reachable":s3,"detail":s3d},
            ],
        }),
    )
}

/// GET /health — all deps + observability block. Only postgres + s3 flip status.
pub async fn health(st: web::Data<AppState>) -> HttpResponse {
    let (pg, pgd) = check_pg(&st).await;
    let (s3, s3d) = check_s3(&st).await;
    let (kf, kfd) = check_kafka(&st.cfg.kafka_bootstrap);
    let (les, lesd) =
        check_es(&st, &st.cfg.log_es_url, &st.cfg.log_es_user, &st.cfg.log_es_password).await;
    let mongo_ok = logging::mongo_healthy();
    let healthy = pg && s3; // kafka/es/mongo are diagnostic-only
    pretty(
        if healthy { 200 } else { 503 },
        json!({
            "status": if healthy { "healthy" } else { "unhealthy" },
            "identity": identity(&st),
            "checks": {
                "postgres":      {"ok": pg,  "detail": pgd},
                "s3":            {"ok": s3,  "detail": s3d},
                "kafka":         {"ok": kf,  "detail": kfd},
                "elasticsearch": {"ok": les, "detail": lesd},
                "mongo_logs":    {"ok": mongo_ok, "detail": if mongo_ok {"ping-ok"} else {"unreachable"}},
            },
            "observability": {
                "apm_service_name": st.cfg.apm_service_name,
                "logs_sink_es":     format!("{}/logs-app-{}-*", st.cfg.log_es_url, st.cfg.service_name),
                "logs_sink_mongo":  format!("{}.{}", st.cfg.mongo_log_db, st.cfg.service_name),
                "trace_otlp":       st.cfg.otlp_endpoint,
            },
        }),
    )
}

/// GET /data — identity block prepended to the read-only data/<tenant>/result.json snapshot.
pub async fn data(st: web::Data<AppState>) -> HttpResponse {
    let rel = format!("data/{}/result.json", st.cfg.tenant);
    let abs = format!("/app/data/{}/result.json", st.cfg.tenant);
    match std::fs::read_to_string(&rel).or_else(|_| std::fs::read_to_string(&abs)) {
        Err(_) => pretty(
            404,
            json!({"error": {"code": "no_snapshot",
                "message": format!("data/{}/result.json not present (run data/{}/collect.sh)", st.cfg.tenant, st.cfg.tenant)}}),
        ),
        Ok(txt) => match serde_json::from_str::<Value>(&txt) {
            Ok(Value::Object(snap)) => {
                let mut out = serde_json::Map::new();
                out.insert("identity".into(), identity(&st));
                for (k, v) in snap {
                    out.insert(k, v);
                }
                pretty(200, Value::Object(out))
            }
            Ok(_) => pretty(
                500,
                json!({"error": {"code": "snapshot_not_object", "message": "snapshot root must be an object"}}),
            ),
            Err(_) => pretty(
                500,
                json!({"error": {"code": "snapshot_not_object", "message": "snapshot is not valid JSON"}}),
            ),
        },
    }
}

/// GET /metrics — Prometheus text (the one non-JSON endpoint).
pub async fn metrics_ep() -> HttpResponse {
    HttpResponse::Ok()
        .content_type("text/plain; version=0.0.4; charset=utf-8")
        .body(metrics::render())
}

/// GET /openapi.json — hand-built spec (every served route appears).
pub async fn openapi_json(st: web::Data<AppState>) -> HttpResponse {
    pretty(200, openapi::spec(&st.cfg))
}

/// GET /docs — Swagger UI.
pub async fn docs() -> HttpResponse {
    HttpResponse::Ok()
        .content_type("text/html; charset=utf-8")
        .body(openapi::SWAGGER_HTML)
}
