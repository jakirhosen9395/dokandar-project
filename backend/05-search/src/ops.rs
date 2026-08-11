//! Operational contract: /ready (PG-gated) /health (all deps) /data /metrics.
use crate::config::Config;
use crate::observability::{apm, apm_otlp, logging, metrics};
use axum::{extract::State, http::StatusCode, response::Response};
use serde_json::{json, Value};
use sqlx::postgres::PgPool;
use std::sync::Arc;
use std::time::{Duration, Instant};

pub struct AppState {
    pub cfg: Config,
    pub pool: Option<PgPool>,
    pub http: reqwest::Client,
    pub boot: Instant,
}

pub fn pretty(code: StatusCode, body: Value) -> Response {
    let txt = serde_json::to_string_pretty(&body).unwrap_or_default() + "\n";
    Response::builder().status(code)
        .header("content-type", "application/json")
        .body(axum::body::Body::from(txt)).unwrap()
}

fn ms(t: Instant) -> f64 { (t.elapsed().as_micros() as f64) / 1000.0 }
fn short(s: &str) -> String { s.chars().take(48).collect() }

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

async fn check_pg(st: &AppState) -> (bool, f64, String) {
    let t = Instant::now();
    match &st.pool {
        None => (false, 0.0, "no-pool".into()),
        Some(p) => {
            let sp = apm_otlp::dep_span("SELECT 1", "postgresql", "SELECT 1");
            let r = sqlx::query("SELECT 1").execute(p).await;
            apm_otlp::end_dep(sp);
            match r {
                Ok(_) => (true, ms(t), "ok".into()),
                Err(e) => (false, ms(t), format!("err:{}", short(&e.to_string()))),
            }
        },
    }
}

async fn check_es(st: &AppState, url: &str, user: &str, pass: &str) -> (bool, f64, String) {
    if url.is_empty() { return (false, 0.0, "url-empty".into()); }
    let t = Instant::now();
    let mut req = st.http.get(format!("{}/_cluster/health", url.trim_end_matches('/')))
        .timeout(Duration::from_secs(2));
    if !user.is_empty() { req = req.basic_auth(user, Some(pass)); }
    let sp = apm_otlp::dep_span("GET _cluster/health", "elasticsearch", "");
    let r = req.send().await;
    apm_otlp::end_dep(sp);
    match r {
        Ok(r) if r.status().is_success() => (true, ms(t), "green".into()),
        Ok(r) => (false, ms(t), format!("http:{}", r.status().as_u16())),
        Err(e) => (false, ms(t), format!("err:{}", short(&e.to_string()))),
    }
}

fn check_kafka(boot: &str) -> (bool, f64, String) {
    let t = Instant::now();
    let (h, p) = boot.rsplit_once(':').unwrap_or((boot, "9092"));
    use std::net::ToSocketAddrs;
    match (h, p.parse::<u16>().unwrap_or(9092)).to_socket_addrs().ok().and_then(|mut a| a.next()) {
        Some(addr) => match std::net::TcpStream::connect_timeout(&addr, Duration::from_secs(2)) {
            Ok(_) => (true, ms(t), "metadata-ok".into()),
            Err(e) => (false, ms(t), format!("err:{:?}", e.kind())),
        },
        None => (false, ms(t), "resolve-failed".into()),
    }
}

pub async fn ready(State(st): State<Arc<AppState>>) -> Response {
    let (ok, l, d) = check_pg(&st).await;
    let body = json!({
        "status": if ok { "ready" } else { "not_ready" },
        "identity": identity(&st),
        "dependencies": [{"name":"postgres","reachable":ok,"latency_ms":l,"detail":d}],
    });
    pretty(if ok { StatusCode::OK } else { StatusCode::SERVICE_UNAVAILABLE }, body)
}

pub async fn health(State(st): State<Arc<AppState>>) -> Response {
    let pg = check_pg(&st).await;
    let ses = check_es(&st, &st.cfg.search_es_url, &st.cfg.search_es_user, &st.cfg.search_es_password).await;
    let les = check_es(&st, &st.cfg.log_es_url, &st.cfg.log_es_user, &st.cfg.log_es_password).await;
    let kf = check_kafka(&st.cfg.kafka_bootstrap);
    let mongo_ok = logging::mongo_healthy();
    let (apm_ok, apm_d) = apm::health_check(&st.cfg);
    let healthy = pg.0 && kf.0; // ES degraded → still healthy (PG tsvector fallback)
    let projection = match &st.pool { Some(p) => crate::projectors::projection_status(p).await, None => json!({}) };
    let body = json!({
        "status": if healthy { "healthy" } else { "unhealthy" },
        "identity": identity(&st),
        "checks": {
            "postgres":             {"ok":pg.0,  "latency_ms":pg.1,  "detail":pg.2},
            "elasticsearch":        {"ok":ses.0, "latency_ms":ses.1, "detail":ses.2},
            "log_elasticsearch":    {"ok":les.0, "latency_ms":les.1, "detail":les.2},
            "kafka":                {"ok":kf.0,  "latency_ms":kf.1,  "detail":kf.2},
            "mongo_logs":           {"ok":mongo_ok, "detail": if mongo_ok {"ping-ok"} else {"unreachable"}},
            "apm":                  {"ok":apm_ok, "detail":apm_d},
        },
        "projection": projection,
        "observability": {
            "apm_service_name": st.cfg.apm_service_name,
            "logs_sink_es":     format!("{}/logs-app-{}-*", st.cfg.log_es_url, st.cfg.service_name),
            "logs_sink_mongo":  format!("{}.{}", st.cfg.mongo_log_db, st.cfg.service_name),
            "search_es":        st.cfg.search_es_url,
        },
    });
    pretty(if healthy { StatusCode::OK } else { StatusCode::SERVICE_UNAVAILABLE }, body)
}

pub async fn data(State(st): State<Arc<AppState>>) -> Response {
    let rel = format!("data/{}/result.json", st.cfg.tenant);
    let abs = format!("/app/data/{}/result.json", st.cfg.tenant);
    match std::fs::read_to_string(&rel).or_else(|_| std::fs::read_to_string(&abs)) {
        Err(_) => pretty(StatusCode::NOT_FOUND, json!({"error":{"code":"no_snapshot",
            "message": format!("data/{}/result.json not present (run data/{}/collect.sh)", st.cfg.tenant, st.cfg.tenant)}})),
        Ok(txt) => match serde_json::from_str::<Value>(&txt) {
            Ok(Value::Object(snap)) => {
                let mut out = serde_json::Map::new();
                out.insert("identity".into(), identity(&st));
                for (k, v) in snap { out.insert(k, v); }
                pretty(StatusCode::OK, Value::Object(out))
            }
            Ok(_) => pretty(StatusCode::INTERNAL_SERVER_ERROR, json!({"error":{"code":"snapshot_parse_failed","message":"snapshot root must be an object"}})),
            Err(_) => pretty(StatusCode::INTERNAL_SERVER_ERROR, json!({"error":{"code":"snapshot_parse_failed","message":"snapshot is not valid JSON"}})),
        },
    }
}

pub async fn metrics_ep() -> Response {
    Response::builder().status(StatusCode::OK)
        .header("content-type", "text/plain; version=0.0.4; charset=utf-8")
        .body(axum::body::Body::from(metrics::render())).unwrap()
}
