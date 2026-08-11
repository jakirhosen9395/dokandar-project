//! Runtime config — read once from the process env (rendered by env/init-env.sh).
//! 12-media is the object-storage gateway: PG metadata store + S3/RustFS bucket + Kafka outbox.
//! Application logs ship to the APM-stack ES (:9200) + Mongo; traces via OTLP → APM.
//! Field names for the observability block are kept identical to 05-search so the ported
//! observability modules (otel.rs / logging.rs) compile unchanged.
use std::env;

fn ev(k: &str) -> String { env::var(k).unwrap_or_default() }
fn ev_or(k: &str, d: &str) -> String { let v = ev(k); if v.is_empty() { d.to_string() } else { v } }
fn ev_u16(k: &str, d: u16) -> u16 { ev(k).parse().unwrap_or(d) }
fn ev_i64(k: &str, d: i64) -> i64 { ev(k).parse().unwrap_or(d) }
fn ev_bool(k: &str, d: bool) -> bool {
    match ev(k).to_ascii_lowercase().as_str() {
        "" => d, "1" | "true" | "yes" | "on" => true, _ => false,
    }
}

#[derive(Clone, Debug)]
pub struct Config {
    // identity block
    pub app_env: String,
    pub service_name: String,
    pub env_version: String,
    pub tenant: String,
    pub service_port: u16,
    pub grpc_port: u16,
    pub log_level: String,
    pub code_version: String,
    // postgres (metadata store, sole writer)
    pub postgres_dsn: String,
    pub postgres_admin_dsn: String,
    pub postgres_db: String,
    // kafka (transactional outbox emits)
    pub kafka_bootstrap: String,
    pub kafka_topic_media_uploaded: String,
    pub kafka_topic_media_deleted: String,
    // S3 / RustFS object store
    pub s3_endpoint: String,
    pub s3_access_key: String,
    pub s3_secret_key: String,
    pub s3_bucket: String,
    pub s3_region: String,
    pub s3_force_path_style: bool,
    // presign TTLs
    pub presign_upload_ttl_seconds: i64,
    pub presign_download_ttl_seconds: i64,
    // mongo forensic log sink
    pub mongo_log_uri: String,
    pub mongo_log_db: String,
    // LOG-SINK ES (:9200, block 07) — logs-app-12-media-*
    pub log_es_url: String,
    pub log_es_user: String,
    pub log_es_password: String,
    // apm (OTLP → Elastic APM Server)
    pub apm_server_url: String,
    pub apm_secret_token: String,
    pub apm_service_name: String,
    pub otlp_endpoint: String,
    // jwt verify-only (RS256) + internal token
    pub jwt_public_key_b64: String,
    pub jwt_issuer: String,
    pub internal_service_token: String,
}

impl Config {
    pub fn from_env() -> Config {
        let code_version = std::fs::read_to_string("CODE_VERSION")
            .or_else(|_| std::fs::read_to_string("/app/CODE_VERSION"))
            .map(|s| s.trim().to_string())
            .unwrap_or_else(|_| "0-unknown".into());
        Config {
            app_env: ev_or("APP_ENV", "dev"),
            service_name: ev_or("SERVICE_NAME", "12-media"),
            env_version: ev_or("ENV_VERSION", "v1.0.0"),
            tenant: ev_or("TENANT", "local"),
            service_port: ev_u16("SERVICE_PORT", 8080),
            grpc_port: ev_u16("GRPC_PORT", 50051),
            log_level: ev_or("LOG_LEVEL", "info"),
            code_version,
            postgres_dsn: ev("POSTGRES_DSN"),
            postgres_admin_dsn: ev("POSTGRES_ADMIN_DSN"),
            postgres_db: ev_or("POSTGRES_DB", "dokandar_media_dev"),
            kafka_bootstrap: ev("KAFKA_BOOTSTRAP"),
            kafka_topic_media_uploaded: ev_or("KAFKA_TOPIC_MEDIA_UPLOADED", "dokandar.media.uploaded"),
            kafka_topic_media_deleted: ev_or("KAFKA_TOPIC_MEDIA_DELETED", "dokandar.media.deleted"),
            s3_endpoint: ev("S3_ENDPOINT"),
            s3_access_key: ev("S3_ACCESS_KEY"),
            s3_secret_key: ev("S3_SECRET_KEY"),
            s3_bucket: ev_or("S3_BUCKET", "dokandar-media-dev"),
            s3_region: ev_or("S3_REGION", "us-east-1"),
            s3_force_path_style: ev_bool("S3_FORCE_PATH_STYLE", true),
            presign_upload_ttl_seconds: ev_i64("PRESIGN_UPLOAD_TTL_SECONDS", 900),
            presign_download_ttl_seconds: ev_i64("PRESIGN_DOWNLOAD_TTL_SECONDS", 300),
            mongo_log_uri: ev("MONGO_LOG_URI"),
            mongo_log_db: ev_or("MONGO_LOG_DB", "mongo_db_dokandar_application_logs"),
            log_es_url: ev("ELASTIC_SEARCH_URL"),
            log_es_user: ev("ELASTIC_SEARCH_USERNAME"),
            log_es_password: ev("ELASTIC_SEARCH_PASSWORD"),
            apm_server_url: ev("APM_SERVER_URL"),
            apm_secret_token: ev("APM_SECRET_TOKEN"),
            apm_service_name: ev_or("APM_SERVICE_NAME", "12-media"),
            otlp_endpoint: ev_or("OTEL_EXPORTER_OTLP_ENDPOINT", &ev("APM_SERVER_URL")),
            jwt_public_key_b64: ev("JWT_PUBLIC_KEY_B64"),
            jwt_issuer: ev_or("JWT_ISSUER", "dokandar-auth"),
            internal_service_token: ev("INTERNAL_SERVICE_TOKEN"),
        }
    }
}
