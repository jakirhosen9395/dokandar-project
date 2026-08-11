//! DOKANDAR 12-media — Rust / Actix Web 4 object-storage gateway.
//! Boot order: config → fail-fast on empty SERVICE_NAME → logging → APM/OTel → PG pool
//! (create-if-missing + migrate) → S3 client + ensure bucket → Kafka producer →
//! spawn (outbox relay, scan/thumbnail worker, gRPC server) → bind the Actix HTTP server.
mod auth;
mod config;
mod db;
mod domain;
mod grpc;
mod http;
mod observability;
mod outbox;
mod s3;
mod worker;

mod pb {
    tonic::include_proto!("dokandar.media.v1");
}

use observability::{logging, otel};
use std::sync::Arc;
use std::time::Instant;

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let cfg = config::Config::from_env();

    // fail-fast: SERVICE_NAME must be present (config defaults it, but guard the contract).
    if cfg.service_name.trim().is_empty() {
        eprintln!("FATAL: SERVICE_NAME is empty");
        std::process::exit(1);
    }

    // baseline stdout tracing for the boot path
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::new(
            std::env::var("RUST_LOG").unwrap_or_else(|_| cfg.log_level.clone()),
        ))
        .with_target(false)
        .init();

    logging::init(&cfg);
    otel::init(&cfg);
    logging::info(
        "media.boot",
        &format!(
            "starting {} code_version={} rest={} grpc={} tenant={} env={}",
            cfg.service_name, cfg.code_version, cfg.service_port, cfg.grpc_port, cfg.tenant, cfg.app_env
        ),
    );

    // PostgreSQL — create-if-missing + migrate before listeners bind. None ⇒ /ready 503.
    let pool = match db::ensure_db_and_pool(&cfg).await {
        Ok(p) => {
            logging::info("media.boot", "postgres pool ready; migrations applied");
            Some(p)
        }
        Err(e) => {
            logging::error("media.boot", &format!("postgres init failed (/ready will be 503): {e}"));
            None
        }
    };

    // S3/RustFS client + ensure the bucket exists.
    let s3 = match s3::S3::connect(&cfg).await {
        Ok(s) => {
            if let Err(e) = s.ensure_bucket().await {
                logging::warn("media.boot", &format!("ensure_bucket: {e}"));
            } else {
                logging::info("media.boot", &format!("s3 bucket ready: {}", cfg.s3_bucket));
            }
            Some(s)
        }
        Err(e) => {
            logging::error("media.boot", &format!("s3 connect failed (/ready will be 503): {e}"));
            None
        }
    };

    // Background tasks (own their own clones) — outbox relay, worker, gRPC server.
    if let Some(p) = &pool {
        match outbox::build_producer(&cfg) {
            Ok(producer) => {
                tokio::spawn(outbox::run(p.clone(), producer, cfg.clone()));
                logging::info("media.boot", "outbox relay spawned");
            }
            Err(e) => logging::error("media.boot", &format!("kafka producer build failed (outbox disabled): {e}")),
        }
        tokio::spawn(worker::run(p.clone(), cfg.clone()));
        logging::info("media.boot", "scan/thumbnail worker spawned");

        if let Some(s) = &s3 {
            tokio::spawn(grpc::serve(cfg.clone(), p.clone(), s.clone()));
            logging::info("media.boot", &format!("gRPC server spawned on :{}", cfg.grpc_port));
        } else {
            logging::warn("media.boot", "gRPC not started (s3 unavailable)");
        }
    } else {
        logging::warn("media.boot", "background tasks not started (postgres unavailable)");
    }

    let http_client = reqwest::Client::builder()
        .danger_accept_invalid_certs(true)
        .build()
        .expect("reqwest client");

    let state = Arc::new(http::AppState {
        cfg,
        pool,
        s3,
        http: http_client,
        boot: Instant::now(),
    });

    http::serve(state).await
}
