//! In-process scan + thumbnail worker (no RabbitMQ in this env). Polls media_objects in state
//! 'uploaded' (FOR UPDATE SKIP LOCKED), runs a stub AV scan + stub thumbnail, drives the object to
//! 'ready', and writes the media.uploaded outbox row — ALL in one DB tx. Adaptive idle backoff.
use crate::config::Config;
use crate::observability::{logging, metrics, otel};
use chrono::Utc;
use serde_json::json;
use sqlx::postgres::PgPool;
use sqlx::Row;
use std::time::Duration;
use uuid::Uuid;

pub async fn run(pool: PgPool, cfg: Config) {
    logging::info("media.worker", "scan+thumbnail worker started");
    let mut idle_ms: u64 = 300;
    loop {
        match process_batch(&pool, &cfg).await {
            Ok(n) if n > 0 => {
                idle_ms = 300;
                continue;
            }
            Ok(_) => {}
            Err(e) => logging::warn("media.worker", &format!("batch error: {e}")),
        }
        tokio::time::sleep(Duration::from_millis(idle_ms)).await;
        idle_ms = (idle_ms * 2).min(5000);
    }
}

/// Claim up to 10 uploaded objects and process each in its own tx. Returns count processed.
async fn process_batch(pool: &PgPool, cfg: &Config) -> Result<usize, sqlx::Error> {
    // claim ids first (short transaction), then process each fully in its own tx.
    let sp = otel::dep_span("SELECT uploaded FOR UPDATE SKIP LOCKED", "postgresql", "");
    let rows = sqlx::query(
        "SELECT id FROM media_objects WHERE state='uploaded' \
         ORDER BY updated_at FOR UPDATE SKIP LOCKED LIMIT 10",
    )
    .fetch_all(pool)
    .await;
    otel::end_dep(sp);
    let ids: Vec<Uuid> = rows?.into_iter().map(|r| r.get::<Uuid, _>("id")).collect();
    let mut done = 0usize;
    for id in ids {
        if let Err(e) = process_one(pool, cfg, id).await {
            logging::warn("media.worker", &format!("process {id} failed: {e}"));
        } else {
            done += 1;
        }
    }
    Ok(done)
}

async fn process_one(pool: &PgPool, cfg: &Config, media_id: Uuid) -> Result<(), sqlx::Error> {
    let mut tx = pool.begin().await?;

    // re-lock the row inside this tx; bail if another worker grabbed it.
    let sp = otel::dep_span("SELECT row FOR UPDATE SKIP LOCKED", "postgresql", "");
    let row = sqlx::query(
        "SELECT owner_id, scope, mime, COALESCE(bytes,0) AS bytes, object_key \
         FROM media_objects WHERE id=$1 AND state='uploaded' \
         FOR UPDATE SKIP LOCKED",
    )
    .bind(media_id)
    .fetch_optional(&mut *tx)
    .await;
    otel::end_dep(sp);
    let row = match row? {
        Some(r) => r,
        None => {
            tx.commit().await?;
            return Ok(());
        }
    };
    let owner: Uuid = row.get("owner_id");
    let scope: String = row.get("scope");
    let mime: String = row.get("mime");
    let bytes: i64 = row.get("bytes");

    // --- stub AV scan: verdict=clean ---
    let verdict = "clean";
    let sp = otel::dep_span("INSERT av_scan_results", "postgresql", "");
    sqlx::query(
        "INSERT INTO av_scan_results (media_id, verdict, engine, signature) VALUES ($1,$2,'stub',NULL)",
    )
    .bind(media_id)
    .bind(verdict)
    .execute(&mut *tx)
    .await?;
    otel::end_dep(sp);

    let sp = otel::dep_span("UPDATE av_clean + state=scanned", "postgresql", "");
    sqlx::query(
        "UPDATE media_objects SET av_clean=true, state='scanned', updated_at=now() WHERE id=$1",
    )
    .bind(media_id)
    .execute(&mut *tx)
    .await?;
    otel::end_dep(sp);
    metrics::MEDIA_SCANNED.with_label_values(&[verdict]).inc();

    // --- stub thumbnail: one derivative 'thumb' at thumb/<scope>/<media_id> ---
    let thumb_key = format!("thumb/{}/{}", scope, media_id);
    let sp = otel::dep_span("INSERT media_derivatives", "postgresql", "");
    sqlx::query(
        "INSERT INTO media_derivatives (media_id, label, object_key, width, height, bytes) \
         VALUES ($1,'thumb',$2,NULL,NULL,NULL) \
         ON CONFLICT (media_id, label) DO UPDATE SET object_key=EXCLUDED.object_key",
    )
    .bind(media_id)
    .bind(&thumb_key)
    .execute(&mut *tx)
    .await?;
    otel::end_dep(sp);

    let sp = otel::dep_span("UPDATE derivatives_ready + state=ready", "postgresql", "");
    sqlx::query(
        "UPDATE media_objects SET derivatives_ready=true, state='ready', updated_at=now() WHERE id=$1",
    )
    .bind(media_id)
    .execute(&mut *tx)
    .await?;
    otel::end_dep(sp);

    // --- media.uploaded outbox row (now servable) — same tx ---
    let payload = json!({
        "media_id": media_id.to_string(),
        "owner_id": owner.to_string(),
        "scope": scope,
        "mime": mime,
        "bytes": bytes,
        "object_key": format!("original/{}/{}", scope, media_id),
        "state": "ready",
        "av_clean": true,
        "ready_at": Utc::now().to_rfc3339(),
    });
    let sp = otel::dep_span("INSERT outbox media.uploaded", "postgresql", "");
    sqlx::query("INSERT INTO outbox (topic, key, payload) VALUES ($1,$2,$3)")
        .bind(&cfg.kafka_topic_media_uploaded)
        .bind(media_id.to_string())
        .bind(sqlx::types::Json(&payload))
        .execute(&mut *tx)
        .await?;
    otel::end_dep(sp);

    tx.commit().await?;
    logging::info("media.worker", &format!("media {media_id} → ready (scanned clean + thumb)"));
    Ok(())
}
