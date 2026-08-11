//! CQRS projectors — consume Kafka domain events → upsert the PostgreSQL *_view store.
//! product.changed (04-catalog) · shop.changed (03-seller) · category.changed (04) ·
//! order.placed (13-order → trending). Consume-only; each topic has its own group.
use crate::config::Config;
use crate::observability::{apm_otlp, logging, metrics};
use opentelemetry::trace::FutureExt;
use rdkafka::config::ClientConfig;
use rdkafka::consumer::{Consumer, StreamConsumer};
use rdkafka::Message;
use serde_json::{json, Value};
use sqlx::postgres::PgPool;
use uuid::Uuid;

fn uuid_opt(v: &Value, k: &str) -> Option<Uuid> { v.get(k).and_then(|x| x.as_str()).and_then(|s| Uuid::parse_str(s).ok()) }
fn str_or(v: &Value, k: &str) -> String { v.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string() }
fn i32_opt(v: &Value, k: &str) -> Option<i32> { v.get(k).and_then(|x| x.as_i64()).map(|n| n as i32) }

pub fn start_all(cfg: &Config, pool: PgPool) {
    let topics = [
        (cfg.topic_product.clone(), "product"),
        (cfg.topic_shop.clone(), "shop"),
        (cfg.topic_category.clone(), "category"),
        (cfg.topic_order.clone(), "order"),
    ];
    for (topic, kind) in topics {
        if topic.is_empty() { continue; }
        metrics::PROJECTION_LAG.with_label_values(&[kind]).set(0);
        let (boot, group, pool, kind) =
            (cfg.kafka_bootstrap.clone(), format!("{}-{}", cfg.kafka_group_prefix, kind), pool.clone(), kind.to_string());
        tokio::spawn(async move { run_consumer(boot, group, topic, kind, pool).await; });
    }
}

async fn run_consumer(boot: String, group: String, topic: String, kind: String, pool: PgPool) {
    let consumer: StreamConsumer = match ClientConfig::new()
        .set("bootstrap.servers", &boot)
        .set("group.id", &group)
        .set("auto.offset.reset", "earliest")
        .set("enable.auto.commit", "true")
        .create()
    {
        Ok(c) => c,
        Err(e) => { logging::error("search.projector", &format!("{kind}: consumer create failed: {e}")); return; }
    };
    if let Err(e) = consumer.subscribe(&[&topic]) {
        logging::error("search.projector", &format!("{kind}: subscribe {topic} failed: {e}")); return;
    }
    logging::info("search.projector", &format!("{kind} projector consuming {topic} (group={group})"));
    loop {
        match consumer.recv().await {
            Err(e) => logging::warn("search.projector", &format!("{kind}: recv error: {e}")),
            Ok(m) => {
                if let Some(p) = m.payload() {
                    match serde_json::from_slice::<Value>(p) {
                        Ok(v) => {
                            let cx = apm_otlp::consume_context(&topic);
                            let work = async {
                                let sp = apm_otlp::dep_span("upsert *_view", "postgresql", "");
                                let r = match kind.as_str() {
                                    "product" => project_product(&pool, &v).await,
                                    "shop" => project_shop(&pool, &v).await,
                                    "category" => project_category(&pool, &v).await,
                                    "order" => project_order(&pool, &v).await,
                                    _ => Ok(()),
                                };
                                apm_otlp::end_dep(sp);
                                r
                            };
                            let r = match cx.clone() { Some(c) => work.with_context(c).await, None => work.await };
                            if let Some(c) = &cx { apm_otlp::end_context(c); }
                            if let Err(e) = r { logging::warn("search.projector", &format!("{kind}: upsert failed: {e}")); }
                        }
                        Err(e) => logging::warn("search.projector", &format!("{kind}: bad json: {e}")),
                    }
                }
            }
        }
    }
}

async fn project_product(pool: &PgPool, v: &Value) -> Result<(), sqlx::Error> {
    let pid = match uuid_opt(v, "product_id") { Some(x) => x, None => return Ok(()) };
    if v.get("change").and_then(|c| c.as_str()) == Some("deleted") {
        sqlx::query("DELETE FROM products_view WHERE product_id=$1").bind(pid).execute(pool).await?;
        return Ok(());
    }
    let shop_ids: Vec<Uuid> = v.get("shop_ids").and_then(|a| a.as_array())
        .map(|a| a.iter().filter_map(|x| x.as_str()).filter_map(|s| Uuid::parse_str(s).ok()).collect())
        .unwrap_or_default();
    let shop_id = shop_ids.first().copied();
    sqlx::query(r#"INSERT INTO products_view
        (product_id,shop_id,shop_ids,owner_id,sharing_model,category_id,name_en,name_bn,list_price_minor,sale_price_minor,is_active,in_stock,updated_at)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,true,true,now())
        ON CONFLICT (product_id) DO UPDATE SET shop_id=EXCLUDED.shop_id,shop_ids=EXCLUDED.shop_ids,owner_id=EXCLUDED.owner_id,
          sharing_model=EXCLUDED.sharing_model,category_id=EXCLUDED.category_id,name_en=EXCLUDED.name_en,name_bn=EXCLUDED.name_bn,
          list_price_minor=EXCLUDED.list_price_minor,sale_price_minor=EXCLUDED.sale_price_minor,updated_at=now()"#)
        .bind(pid).bind(shop_id).bind(&shop_ids).bind(uuid_opt(v, "owner_id"))
        .bind(v.get("sharing_model").and_then(|x| x.as_str()).unwrap_or("shared"))
        .bind(uuid_opt(v, "category_id")).bind(str_or(v, "name_en")).bind(str_or(v, "name_bn"))
        .bind(i32_opt(v, "list_price_minor").unwrap_or(0)).bind(i32_opt(v, "sale_price_minor"))
        .execute(pool).await?;
    Ok(())
}

async fn project_shop(pool: &PgPool, v: &Value) -> Result<(), sqlx::Error> {
    let sid = match uuid_opt(v, "shop_id") { Some(x) => x, None => return Ok(()) };
    let handle = str_or(v, "handle");
    if handle.is_empty() { return Ok(()); }
    let name_en = v.get("name").and_then(|x| x.as_str()).unwrap_or("").to_string();
    let lat = v.get("lat").and_then(|x| x.as_f64());
    let lng = v.get("lon").or_else(|| v.get("lng")).and_then(|x| x.as_f64());
    let active = v.get("status").and_then(|x| x.as_str()) == Some("active");
    sqlx::query(r#"INSERT INTO shops_view (shop_id,owner_id,handle,name_en,name_bn,category_id,lat,lng,is_active,open_now,updated_at)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$9,now())
        ON CONFLICT (shop_id) DO UPDATE SET owner_id=EXCLUDED.owner_id,handle=EXCLUDED.handle,name_en=EXCLUDED.name_en,
          name_bn=EXCLUDED.name_bn,category_id=EXCLUDED.category_id,lat=EXCLUDED.lat,lng=EXCLUDED.lng,
          is_active=EXCLUDED.is_active,open_now=EXCLUDED.open_now,updated_at=now()"#)
        .bind(sid).bind(uuid_opt(v, "owner_id")).bind(&handle).bind(&name_en).bind(str_or(v, "name_bn"))
        .bind(uuid_opt(v, "category_id")).bind(lat).bind(lng).bind(active)
        .execute(pool).await?;
    Ok(())
}

async fn project_category(pool: &PgPool, v: &Value) -> Result<(), sqlx::Error> {
    let cid = match uuid_opt(v, "category_id") { Some(x) => x, None => return Ok(()) };
    sqlx::query(r#"INSERT INTO categories_view (category_id,parent_id,name_en,name_bn,is_active) VALUES ($1,$2,$3,$4,true)
        ON CONFLICT (category_id) DO UPDATE SET parent_id=EXCLUDED.parent_id,name_en=EXCLUDED.name_en,name_bn=EXCLUDED.name_bn"#)
        .bind(cid).bind(uuid_opt(v, "parent_id")).bind(str_or(v, "name_en")).bind(str_or(v, "name_bn"))
        .execute(pool).await?;
    Ok(())
}

async fn project_order(pool: &PgPool, v: &Value) -> Result<(), sqlx::Error> {
    if let Some(items) = v.get("items").and_then(|x| x.as_array()) {
        for it in items {
            if let Some(pid) = uuid_opt(it, "product_id") {
                let qty = i32_opt(it, "quantity").or_else(|| i32_opt(it, "qty")).unwrap_or(1);
                sqlx::query(r#"INSERT INTO trending_counters (product_id,bucket_date,order_count) VALUES ($1,current_date,$2)
                    ON CONFLICT (product_id,bucket_date) DO UPDATE SET order_count=trending_counters.order_count+EXCLUDED.order_count"#)
                    .bind(pid).bind(qty).execute(pool).await?;
            }
        }
    }
    Ok(())
}

pub async fn projection_status(pool: &PgPool) -> Value {
    async fn c(pool: &PgPool, t: &str) -> i64 {
        sqlx::query_scalar::<_, i64>(&format!("SELECT count(*) FROM {t}")).fetch_one(pool).await.unwrap_or(-1)
    }
    let (pv, sv, cv) = (c(pool, "products_view").await, c(pool, "shops_view").await, c(pool, "categories_view").await);
    metrics::VIEW_ROWS.with_label_values(&["products_view"]).set(pv);
    metrics::VIEW_ROWS.with_label_values(&["shops_view"]).set(sv);
    metrics::VIEW_ROWS.with_label_values(&["categories_view"]).set(cv);
    json!({ "products_view": pv, "shops_view": sv, "categories_view": cv })
}
