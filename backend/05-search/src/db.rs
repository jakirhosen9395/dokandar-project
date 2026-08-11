//! PostgreSQL pool + ensure-db/migrate. The *_view tables are the read model
//! (sole writer = the Kafka projectors). Runtime sqlx queries only (no compile-time macros).
use crate::config::Config;
use sqlx::postgres::{PgPool, PgPoolOptions};

pub async fn ensure_db_and_pool(cfg: &Config) -> anyhow::Result<PgPool> {
    // 1) ensure the per-service database exists (connect to the admin 'postgres' db)
    match PgPoolOptions::new().max_connections(1).acquire_timeout(std::time::Duration::from_secs(5))
        .connect(&cfg.pg_admin_dsn()).await
    {
        Ok(admin) => {
            let exists: Option<(i32,)> = sqlx::query_as("SELECT 1 FROM pg_database WHERE datname = $1")
                .bind(&cfg.pg_db).fetch_optional(&admin).await.unwrap_or(None);
            if exists.is_none() {
                let _ = sqlx::raw_sql(&format!("CREATE DATABASE \"{}\"", cfg.pg_db)).execute(&admin).await;
            }
            admin.close().await;
        }
        Err(e) => tracing::warn!("admin connect failed (db may already exist): {e}"),
    }
    // 2) connect to the service db
    let pool = PgPoolOptions::new().max_connections(10).acquire_timeout(std::time::Duration::from_secs(5))
        .connect(&cfg.pg_dsn()).await?;
    // 3) run migrations (idempotent) — multi-statement file via the simple protocol
    let mig = std::fs::read_to_string("migrations/0001_init.sql")
        .or_else(|_| std::fs::read_to_string("/app/migrations/0001_init.sql"))?;
    sqlx::raw_sql(&mig).execute(&pool).await?;
    Ok(pool)
}
