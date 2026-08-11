//! Transactional-outbox relay: poll outbox rows WHERE sent_at IS NULL (FOR UPDATE SKIP LOCKED),
//! produce to Kafka acks=all keyed by media_id, mark sent_at, repeat. Drives the media.uploaded /
//! media.deleted topics. The media_outbox_pending gauge exposes relay lag.
use crate::config::Config;
use crate::observability::{logging, metrics, otel};
use rdkafka::config::ClientConfig;
use rdkafka::producer::{FutureProducer, FutureRecord};
use sqlx::postgres::PgPool;
use sqlx::Row;
use std::time::Duration;

/// Build the acks=all FutureProducer (idempotent, durable).
pub fn build_producer(cfg: &Config) -> anyhow::Result<FutureProducer> {
    let producer: FutureProducer = ClientConfig::new()
        .set("bootstrap.servers", &cfg.kafka_bootstrap)
        .set("acks", "all")
        .set("enable.idempotence", "true")
        .set("message.timeout.ms", "10000")
        .create()?;
    Ok(producer)
}

pub async fn run(pool: PgPool, producer: FutureProducer, _cfg: Config) {
    logging::info("media.outbox", "outbox relay started");
    let mut idle_ms: u64 = 200;
    loop {
        match drain_once(&pool, &producer).await {
            Ok(n) => {
                refresh_pending_gauge(&pool).await;
                if n > 0 {
                    idle_ms = 200; // work found → poll fast
                    continue;
                }
            }
            Err(e) => {
                logging::warn("media.outbox", &format!("relay cycle error: {e}"));
            }
        }
        // adaptive idle backoff up to ~3s
        tokio::time::sleep(Duration::from_millis(idle_ms)).await;
        idle_ms = (idle_ms * 2).min(3000);
    }
}

/// Claim up to 100 unsent rows, publish them, mark sent. Returns the number published.
async fn drain_once(pool: &PgPool, producer: &FutureProducer) -> Result<usize, sqlx::Error> {
    let mut tx = pool.begin().await?;
    let sp = otel::dep_span("SELECT outbox unsent FOR UPDATE SKIP LOCKED", "postgresql", "");
    let rows = sqlx::query(
        "SELECT id, topic, key, payload FROM outbox \
         WHERE sent_at IS NULL ORDER BY id \
         FOR UPDATE SKIP LOCKED LIMIT 100",
    )
    .fetch_all(&mut *tx)
    .await;
    otel::end_dep(sp);
    let rows = rows?;
    if rows.is_empty() {
        tx.commit().await?;
        return Ok(0);
    }

    let mut published_ids: Vec<i64> = Vec::with_capacity(rows.len());
    for r in &rows {
        let id: i64 = r.get("id");
        let topic: String = r.get("topic");
        let key: Option<String> = r.try_get("key").ok();
        let payload: serde_json::Value = r.get("payload");
        let body = serde_json::to_vec(&payload).unwrap_or_default();
        let key_str = key.unwrap_or_else(|| id.to_string());

        let sp = otel::dep_span(&format!("produce {topic}"), "kafka", &topic);
        let rec = FutureRecord::to(&topic).payload(&body).key(&key_str);
        let res = producer.send(rec, Duration::from_secs(10)).await;
        otel::end_dep(sp);
        match res {
            Ok(_) => {
                published_ids.push(id);
                metrics::MEDIA_OUTBOX_PUBLISHED.inc();
            }
            Err((e, _)) => {
                logging::warn("media.outbox", &format!("produce to {topic} failed: {e}"));
                // stop on first failure; the unmarked rows are retried next cycle.
                break;
            }
        }
    }

    if !published_ids.is_empty() {
        let sp = otel::dep_span("UPDATE outbox sent_at", "postgresql", "");
        sqlx::query("UPDATE outbox SET sent_at=now() WHERE id = ANY($1)")
            .bind(&published_ids)
            .execute(&mut *tx)
            .await?;
        otel::end_dep(sp);
    }
    tx.commit().await?;
    Ok(published_ids.len())
}

async fn refresh_pending_gauge(pool: &PgPool) {
    let n: i64 = sqlx::query_scalar::<_, i64>("SELECT count(*) FROM outbox WHERE sent_at IS NULL")
        .fetch_one(pool)
        .await
        .unwrap_or(0);
    metrics::MEDIA_OUTBOX_PENDING.set(n);
}
