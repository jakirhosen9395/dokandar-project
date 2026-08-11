//! Runtime config — read once from the process env (rendered by env/init-env.sh).
//! 05-search is a CQRS read projection: PG *_view store + business SEARCH ES (:9201);
//! application logs ship to the APM-stack ES (:9200) + Mongo; traces via OTLP → APM.
use std::env;

fn ev(k: &str) -> String { env::var(k).unwrap_or_default() }
fn ev_or(k: &str, d: &str) -> String { let v = ev(k); if v.is_empty() { d.to_string() } else { v } }
fn ev_u16(k: &str, d: u16) -> u16 { ev(k).parse().unwrap_or(d) }
fn ev_i64(k: &str, d: i64) -> i64 { ev(k).parse().unwrap_or(d) }

#[derive(Clone, Debug)]
pub struct Config {
    pub app_env: String,
    pub service_name: String,
    pub env_version: String,
    pub tenant: String,
    pub service_port: u16,
    pub code_version: String,
    // postgres (the *_view projection store)
    pub pg_host: String,
    pub pg_port: u16,
    pub pg_user: String,
    pub pg_password: String,
    pub pg_db: String,
    // search tuning
    pub search_default_page_size: i64,
    pub search_max_page_size: i64,
    pub search_geo_default_radius_km: i64,
    pub search_geo_max_radius_km: i64,
    // business SEARCH ES (:9201, block 03) — dokandar-products/-shops
    pub search_es_url: String,
    pub search_es_user: String,
    pub search_es_password: String,
    pub es_index_products: String,
    pub es_index_shops: String,
    // LOG-SINK ES (:9200, block 07) — logs-app-05-search-*
    pub log_es_url: String,
    pub log_es_user: String,
    pub log_es_password: String,
    // kafka (consume-only; projectors added later)
    pub kafka_bootstrap: String,
    pub kafka_group_prefix: String,
    pub topic_product: String,
    pub topic_shop: String,
    pub topic_category: String,
    pub topic_order: String,
    // mongo forensic log sink
    pub mongo_log_uri: String,
    pub mongo_log_db: String,
    // apm (OTLP → Elastic APM Server)
    pub apm_server_url: String,
    pub apm_secret_token: String,
    pub apm_service_name: String,
    pub otlp_endpoint: String,
    // jwt verify-only (admin reindex)
    pub jwt_public_key_b64: String,
    pub jwt_issuer: String,
}

impl Config {
    pub fn from_env() -> Config {
        let code_version = std::fs::read_to_string("CODE_VERSION")
            .or_else(|_| std::fs::read_to_string("/app/CODE_VERSION"))
            .map(|s| s.trim().to_string())
            .unwrap_or_else(|_| "0-unknown".into());
        Config {
            app_env: ev_or("APP_ENV", "dev"),
            service_name: ev_or("SERVICE_NAME", "05-search"),
            env_version: ev_or("ENV_VERSION", "v1.0.0"),
            tenant: ev_or("TENANT", "local"),
            service_port: ev_u16("SERVICE_PORT", 8080),
            code_version,
            pg_host: ev("POSTGRES_HOST"),
            pg_port: ev_u16("POSTGRES_PORT", 5432),
            pg_user: ev("POSTGRES_USER"),
            pg_password: ev("POSTGRES_PASSWORD"),
            pg_db: ev_or("POSTGRES_DB", "dokandar_search_dev"),
            search_default_page_size: ev_i64("SEARCH_DEFAULT_PAGE_SIZE", 20),
            search_max_page_size: ev_i64("SEARCH_MAX_PAGE_SIZE", 100),
            search_geo_default_radius_km: ev_i64("SEARCH_GEO_DEFAULT_RADIUS_KM", 5),
            search_geo_max_radius_km: ev_i64("SEARCH_GEO_MAX_RADIUS_KM", 30),
            search_es_url: ev("SEARCH_ES_URL"),
            search_es_user: ev("SEARCH_ES_USERNAME"),
            search_es_password: ev("SEARCH_ES_PASSWORD"),
            es_index_products: ev_or("ES_INDEX_PRODUCTS", "dokandar-products"),
            es_index_shops: ev_or("ES_INDEX_SHOPS", "dokandar-shops"),
            log_es_url: ev("ELASTIC_SEARCH_URL"),
            log_es_user: ev("ELASTIC_SEARCH_USERNAME"),
            log_es_password: ev("ELASTIC_SEARCH_PASSWORD"),
            kafka_bootstrap: ev("KAFKA_BOOTSTRAP"),
            kafka_group_prefix: ev_or("KAFKA_GROUP_PREFIX", "search"),
            topic_product: ev_or("KAFKA_TOPIC_PRODUCT_CHANGED", "dokandar.product.changed"),
            topic_shop: ev_or("KAFKA_TOPIC_SHOP_CHANGED", "dokandar.shop.changed"),
            topic_category: ev_or("KAFKA_TOPIC_CATEGORY_CHANGED", "dokandar.category.changed"),
            topic_order: ev_or("KAFKA_TOPIC_ORDER_PLACED", "dokandar.order.placed"),
            mongo_log_uri: ev("MONGO_LOG_URI"),
            mongo_log_db: ev_or("MONGO_LOG_DB", "mongo_db_dokandar_application_logs"),
            apm_server_url: ev("APM_SERVER_URL"),
            apm_secret_token: ev("APM_SECRET_TOKEN"),
            apm_service_name: ev_or("APM_SERVICE_NAME", "05-search"),
            otlp_endpoint: ev_or("OTEL_EXPORTER_OTLP_ENDPOINT", &ev("APM_SERVER_URL")),
            jwt_public_key_b64: ev("JWT_PUBLIC_KEY_B64"),
            jwt_issuer: ev_or("JWT_ISSUER", "dokandar-auth"),
        }
    }
    pub fn pg_dsn(&self) -> String {
        format!("postgres://{}:{}@{}:{}/{}", self.pg_user, self.pg_password, self.pg_host, self.pg_port, self.pg_db)
    }
    pub fn pg_admin_dsn(&self) -> String {
        format!("postgres://{}:{}@{}:{}/postgres", self.pg_user, self.pg_password, self.pg_host, self.pg_port)
    }
}
