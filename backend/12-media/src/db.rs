//! PostgreSQL pool + create-if-missing + migrate, run BEFORE the HTTP/gRPC listeners bind.
//! Runtime sqlx queries only (no compile-time macros). 12-media is the sole writer of its
//! metadata store (media_objects/derivatives/av_scan_results/grants/outbox).
use crate::config::Config;
use sqlx::postgres::{PgPool, PgPoolOptions};

/// Valid Postgres identifier for the DB name we may CREATE — prevents injection into the
/// non-parameterizable `CREATE DATABASE "<name>"` statement.
fn valid_db_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 63
        && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        && name.chars().next().map(|c| c.is_ascii_alphabetic() || c == '_').unwrap_or(false)
}

/// Ensure the per-service database exists, then connect a pool and run migrations (idempotent).
/// - `admin_dsn`: DSN to the cluster admin db (e.g. .../postgres) used to CREATE DATABASE.
/// - `db_name`:   the database to create-if-missing (validated against `valid_db_name`).
/// - `dsn`:       DSN to the service database, used for the returned pool + migrations.
///
/// CREATE DATABASE races / already-exists are swallowed (multiple replicas may boot together).
pub async fn ensure_db(admin_dsn: &str, db_name: &str, dsn: &str) -> anyhow::Result<PgPool> {
    if !valid_db_name(db_name) {
        anyhow::bail!("invalid POSTGRES_DB name: {db_name:?}");
    }
    // 1) ensure the database exists (connect to the admin db)
    if !admin_dsn.is_empty() {
        match PgPoolOptions::new().max_connections(1)
            .acquire_timeout(std::time::Duration::from_secs(5))
            .connect(admin_dsn).await
        {
            Ok(admin) => {
                let exists: Option<(i32,)> = sqlx::query_as("SELECT 1 FROM pg_database WHERE datname = $1")
                    .bind(db_name).fetch_optional(&admin).await.unwrap_or(None);
                if exists.is_none() {
                    // CREATE DATABASE cannot be parameterized; db_name is regex-validated above.
                    if let Err(e) = sqlx::raw_sql(&format!("CREATE DATABASE \"{}\"", db_name)).execute(&admin).await {
                        let m = e.to_string();
                        if !m.contains("already exists") { tracing::warn!("CREATE DATABASE {db_name} failed: {m}"); }
                    }
                }
                admin.close().await;
            }
            Err(e) => tracing::warn!("admin connect failed (db may already exist): {e}"),
        }
    }

    // 2) connect to the service db
    let pool = PgPoolOptions::new().max_connections(10)
        .acquire_timeout(std::time::Duration::from_secs(5))
        .connect(dsn).await?;

    // 3) run migrations — full multi-statement file via the simple protocol (idempotent, IF NOT EXISTS).
    let mig = std::fs::read_to_string("migrations/0001_init.sql")
        .or_else(|_| std::fs::read_to_string("/app/migrations/0001_init.sql"))?;
    sqlx::raw_sql(&mig).execute(&pool).await?;
    Ok(pool)
}

/// Convenience wrapper deriving the three DSNs/name from Config.
pub async fn ensure_db_and_pool(cfg: &Config) -> anyhow::Result<PgPool> {
    ensure_db(&cfg.postgres_admin_dsn, &cfg.postgres_db, &cfg.postgres_dsn).await
}
