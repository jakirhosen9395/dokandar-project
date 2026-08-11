//! Fleet-standard logging (ECS, matching 01-auth):
//!   * APP EVENTS  → ECS JSON ({log.level, log.logger, service.{name,version,environment},
//!     host.name, trace/transaction/span ids, message}) to 3 sinks: stdout + MongoDB + ES
//!     data stream logs-app-12-media-default.
//!   * ACCESS LOG  → a single plain line to stdout ONLY (the APM transaction is the
//!     structured record); /ready + /metrics are excluded by the caller.
//! All sinks are bounded fire-and-forget — overflow drops silently. Ported from 05-search
//! (apm_otlp→otel, 05-search→12-media). trace_id is read from the current OTel context.
use crate::config::Config;
use crate::observability::otel;
use chrono::Utc;
use serde_json::{json, Value};
use std::sync::OnceLock;
use tokio::sync::mpsc::{unbounded_channel, UnboundedSender};

static MONGO_TX: OnceLock<UnboundedSender<Value>> = OnceLock::new();
static ES_TX: OnceLock<UnboundedSender<Value>> = OnceLock::new();
static IDENT: OnceLock<(String, String, String, String)> = OnceLock::new(); // name, version, env, host
static MONGO_OK: OnceLock<std::sync::atomic::AtomicBool> = OnceLock::new();

fn mongo_flag() -> &'static std::sync::atomic::AtomicBool { MONGO_OK.get_or_init(|| std::sync::atomic::AtomicBool::new(false)) }
pub fn mongo_healthy() -> bool { mongo_flag().load(std::sync::atomic::Ordering::Relaxed) }
fn ident() -> (&'static str, &'static str, &'static str, &'static str) {
    IDENT.get().map(|(n, v, e, h)| (n.as_str(), v.as_str(), e.as_str(), h.as_str())).unwrap_or(("12-media", "", "dev", ""))
}

fn emit_inner(level: &str, logger: &str, message: &str, extra: Value, trace: Option<(String, String)>) {
    let (name, version, env, host) = ident();
    let mut rec = json!({
        "@timestamp": Utc::now().to_rfc3339(),
        "log": { "level": level, "logger": logger },
        "message": message,
        "service": { "name": name, "version": version, "environment": env },
        "host": { "name": host },
        "ecs": { "version": "8.11" },
    });
    if let Value::Object(ref mut m) = rec {
        match trace {
            Some((tid, sid)) => { m.insert("trace".into(), json!({ "id": tid })); if !sid.is_empty() { m.insert("transaction".into(), json!({ "id": sid })); } m.insert("span".into(), json!({ "id": Value::Null })); }
            None => { m.insert("trace".into(), json!({ "id": Value::Null })); }
        }
    }
    if let (Value::Object(m), Value::Object(ex)) = (&mut rec, extra) { for (k, v) in ex { m.insert(k, v); } }
    println!("{}", serde_json::to_string(&rec).unwrap_or_default());
    if let Some(tx) = MONGO_TX.get() { let _ = tx.send(rec.clone()); }
    if let Some(tx) = ES_TX.get() { let _ = tx.send(rec); }
}

pub fn emit(level: &str, logger: &str, message: &str, extra: Value) { emit_inner(level, logger, message, extra, otel::current_ids()); }
pub fn info(logger: &str, msg: &str) { emit("INFO", logger, msg, json!({})); }
pub fn warn(logger: &str, msg: &str) { emit("WARNING", logger, msg, json!({})); }
pub fn error(logger: &str, msg: &str) { emit("ERROR", logger, msg, json!({})); }

/// Plain access log → stdout only. The structured record is the APM transaction.
/// Caller MUST exclude /ready + /metrics. Never log presigned URLs (bearer capabilities).
pub fn access(method: &str, path: &str, _route: &str, status: u16, dur_ms: f64, rid: &str, _trace_id: Option<&str>) {
    println!("{} {} {} {:.2}ms request_id={}", method, path, status, dur_ms, rid);
}

pub fn init(cfg: &Config) {
    let host = std::fs::read_to_string("/etc/hostname").map(|s| s.trim().to_string()).unwrap_or_default();
    IDENT.set((cfg.service_name.clone(), cfg.code_version.clone(), cfg.app_env.clone(), host)).ok();
    if !cfg.mongo_log_uri.is_empty() {
        let (tx, mut rx) = unbounded_channel::<Value>();
        MONGO_TX.set(tx).ok();
        let (uri, dbn, coll) = (cfg.mongo_log_uri.clone(), cfg.mongo_log_db.clone(), cfg.service_name.clone());
        tokio::spawn(async move {
            let client = match mongodb::Client::with_uri_str(&uri).await { Ok(c) => c, Err(e) => { eprintln!("mongo sink connect failed: {e}"); return; } };
            if client.database("admin").run_command(bson::doc! {"ping": 1}).await.is_ok() { mongo_flag().store(true, std::sync::atomic::Ordering::Relaxed); }
            let col = client.database(&dbn).collection::<bson::Document>(&coll);
            loop {
                let first = match rx.recv().await { Some(v) => v, None => break };
                let mut batch = vec![first];
                while let Ok(v) = rx.try_recv() { batch.push(v); if batch.len() >= 200 { break; } }
                let docs: Vec<bson::Document> = batch.iter().filter_map(|v| bson::to_document(v).ok()).collect();
                if !docs.is_empty() { let ok = col.insert_many(docs).await.is_ok(); mongo_flag().store(ok, std::sync::atomic::Ordering::Relaxed); }
            }
        });
    }
    if !cfg.log_es_url.is_empty() {
        let (tx, mut rx) = unbounded_channel::<Value>();
        ES_TX.set(tx).ok();
        let (url, user, pass) = (cfg.log_es_url.clone(), cfg.log_es_user.clone(), cfg.log_es_password.clone());
        let ds = format!("logs-app-{}-default", cfg.service_name);
        tokio::spawn(async move {
            let client = reqwest::Client::builder().danger_accept_invalid_certs(true).timeout(std::time::Duration::from_secs(5)).build().unwrap();
            let bulk_url = format!("{}/{}/_bulk", url.trim_end_matches('/'), ds);
            loop {
                let first = match rx.recv().await { Some(v) => v, None => break };
                let mut batch = vec![first];
                while let Ok(v) = rx.try_recv() { batch.push(v); if batch.len() >= 200 { break; } }
                let mut body = String::new();
                for v in &batch { body.push_str("{\"create\":{}}\n"); body.push_str(&serde_json::to_string(v).unwrap_or_default()); body.push('\n'); }
                let _ = client.post(&bulk_url).basic_auth(&user, Some(&pass)).header("Content-Type", "application/x-ndjson").body(body).send().await;
            }
        });
    }
}
