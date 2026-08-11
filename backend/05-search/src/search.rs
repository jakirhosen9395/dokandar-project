//! Business discovery API — /api/v1/search/* (public reads + admin reindex).
//! PostgreSQL builds the JSON (json_build_object/json_agg) so the Rust stays thin.
use crate::auth;
use crate::observability::apm_otlp;
use crate::ops::{pretty, AppState};
use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::Response;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;

fn rid(h: &HeaderMap) -> String { h.get("x-request-id").and_then(|v| v.to_str().ok()).unwrap_or("").to_string() }
fn err(code: StatusCode, ecode: &str, msg: &str, r: &str) -> Response {
    pretty(code, json!({"error": {"code": ecode, "message": msg, "request_id": r}}))
}
fn qp<'a>(m: &'a HashMap<String, String>, k: &str) -> Option<&'a String> { m.get(k).filter(|s| !s.is_empty()) }

const PRODUCTS_SQL: &str = r#"
WITH base AS (
  SELECT * FROM products_view
  WHERE is_active = true
    AND ($1 = '' OR tsv_en @@ plainto_tsquery('english',$1) OR tsv_bn @@ plainto_tsquery('simple',$1)
         OR name_en ILIKE '%'||$1||'%' OR name_bn ILIKE '%'||$1||'%')
    AND ($2 = '' OR category_id = nullif($2,'')::uuid)
)
SELECT json_build_object(
  'total', (SELECT count(*) FROM base),
  'items', coalesce((SELECT json_agg(json_build_object(
        'product_id',product_id,'shop_id',shop_id,'category_id',category_id,
        'name_en',name_en,'name_bn',name_bn,'slug',slug,
        'list_price_minor',list_price_minor,'sale_price_minor',sale_price_minor,
        'rating_avg',rating_avg,'rating_count',rating_count,'in_stock',in_stock))
      FROM (SELECT * FROM base ORDER BY rating_avg DESC NULLS LAST LIMIT $3 OFFSET $4) p), '[]'::json),
  'facets', json_build_object('category', coalesce(
      (SELECT json_object_agg(category_id::text, c) FROM
         (SELECT category_id, count(*) c FROM base WHERE category_id IS NOT NULL GROUP BY category_id) f), '{}'::json))
) AS r"#;

pub async fn products(State(st): State<Arc<AppState>>, h: HeaderMap, Query(m): Query<HashMap<String, String>>) -> Response {
    let r = rid(&h);
    let locale = qp(&m, "locale").map(|s| s.as_str()).unwrap_or("en");
    if locale != "en" && locale != "bn" { return err(StatusCode::UNPROCESSABLE_ENTITY, "invalid_request", "locale must be 'en' or 'bn'", &r); }
    let size: i64 = qp(&m, "size").and_then(|s| s.parse().ok()).unwrap_or(st.cfg.search_default_page_size);
    if size < 1 || size > st.cfg.search_max_page_size { return err(StatusCode::UNPROCESSABLE_ENTITY, "invalid_request", &format!("size must be 1..{}", st.cfg.search_max_page_size), &r); }
    let page: i64 = qp(&m, "page").and_then(|s| s.parse().ok()).unwrap_or(1).max(1);
    let cat = qp(&m, "category_id").map(|s| s.as_str()).unwrap_or("");
    if !cat.is_empty() && uuid::Uuid::parse_str(cat).is_err() { return err(StatusCode::UNPROCESSABLE_ENTITY, "invalid_request", "category_id must be a UUID", &r); }
    let pool = match &st.pool { Some(p) => p, None => return err(StatusCode::SERVICE_UNAVAILABLE, "dependency_unavailable", "postgres unavailable", &r) };
    let qstr = qp(&m, "q").map(|s| s.as_str()).unwrap_or("");
    let offset = (page - 1) * size;
    let __sp = apm_otlp::dep_span("SELECT products_view", "postgresql", PRODUCTS_SQL);
    let __r = sqlx::query_scalar::<_, Value>(PRODUCTS_SQL).bind(qstr).bind(cat).bind(size).bind(offset).fetch_one(pool).await;
    apm_otlp::end_dep(__sp);
    match __r {
        Ok(mut v) => { if let Value::Object(ref mut o) = v { o.insert("page".into(), json!(page)); o.insert("size".into(), json!(size)); o.insert("locale".into(), json!(locale)); } pretty(StatusCode::OK, v) }
        Err(_) => err(StatusCode::INTERNAL_SERVER_ERROR, "internal_error", "search query failed", &r),
    }
}

const AUTOCOMPLETE_SQL: &str = r#"
SELECT json_build_object('suggestions', coalesce(json_agg(json_build_object('text',name,'product_id',product_id)), '[]'::json)) AS r
FROM (
  SELECT product_id, CASE WHEN $2='bn' THEN name_bn ELSE name_en END AS name,
         greatest(similarity(name_en,$1), similarity(name_bn,$1)) AS sim
  FROM products_view
  WHERE is_active AND (name_en ILIKE '%'||$1||'%' OR name_bn ILIKE '%'||$1||'%')
  ORDER BY sim DESC LIMIT 10
) s"#;

pub async fn autocomplete(State(st): State<Arc<AppState>>, h: HeaderMap, Query(m): Query<HashMap<String, String>>) -> Response {
    let r = rid(&h);
    let qstr = match qp(&m, "q") { Some(q) => q.as_str(), None => return err(StatusCode::UNPROCESSABLE_ENTITY, "invalid_request", "q is required", &r) };
    let locale = qp(&m, "locale").map(|s| s.as_str()).unwrap_or("en");
    if locale != "en" && locale != "bn" { return err(StatusCode::UNPROCESSABLE_ENTITY, "invalid_request", "locale must be 'en' or 'bn'", &r); }
    let pool = match &st.pool { Some(p) => p, None => return err(StatusCode::SERVICE_UNAVAILABLE, "dependency_unavailable", "postgres unavailable", &r) };
    let __sp = apm_otlp::dep_span("SELECT autocomplete", "postgresql", AUTOCOMPLETE_SQL);
    let __r = sqlx::query_scalar::<_, Value>(AUTOCOMPLETE_SQL).bind(qstr).bind(locale).fetch_one(pool).await;
    apm_otlp::end_dep(__sp);
    match __r {
        Ok(v) => pretty(StatusCode::OK, v),
        Err(_) => err(StatusCode::INTERNAL_SERVER_ERROR, "internal_error", "autocomplete query failed", &r),
    }
}

const SHOPS_SQL: &str = r#"
WITH base AS (
  SELECT *, earth_distance(earth_loc, ll_to_earth($1,$2)) AS dist_m
  FROM shops_view
  WHERE is_active AND lat IS NOT NULL AND lng IS NOT NULL
    AND earth_box(ll_to_earth($1,$2), $3) @> earth_loc
    AND earth_distance(earth_loc, ll_to_earth($1,$2)) <= $3
    AND ($4 = '' OR tsv_en @@ plainto_tsquery('english',$4) OR name_en ILIKE '%'||$4||'%' OR name_bn ILIKE '%'||$4||'%')
)
SELECT json_build_object(
  'total', (SELECT count(*) FROM base),
  'items', coalesce((SELECT json_agg(json_build_object(
       'shop_id',shop_id,'handle',handle,'name_en',name_en,'name_bn',name_bn,
       'lat',lat,'lng',lng,'distance_km',round((dist_m/1000.0)::numeric,2),
       'rating_avg',rating_avg,'rating_count',rating_count,'open_now',open_now) ORDER BY dist_m) FROM base), '[]'::json)
) AS r"#;

pub async fn shops(State(st): State<Arc<AppState>>, h: HeaderMap, Query(m): Query<HashMap<String, String>>) -> Response {
    let r = rid(&h);
    let lat: f64 = match qp(&m, "lat").and_then(|s| s.parse().ok()) { Some(v) => v, None => return err(StatusCode::UNPROCESSABLE_ENTITY, "invalid_request", "lat is required", &r) };
    let lng: f64 = match qp(&m, "lng").and_then(|s| s.parse().ok()) { Some(v) => v, None => return err(StatusCode::UNPROCESSABLE_ENTITY, "invalid_request", "lng is required", &r) };
    if !(-90.0..=90.0).contains(&lat) { return err(StatusCode::UNPROCESSABLE_ENTITY, "invalid_request", "lat must be -90..90", &r); }
    if !(-180.0..=180.0).contains(&lng) { return err(StatusCode::UNPROCESSABLE_ENTITY, "invalid_request", "lng must be -180..180", &r); }
    let radius: i64 = qp(&m, "radius_km").and_then(|s| s.parse().ok()).unwrap_or(st.cfg.search_geo_default_radius_km);
    if radius < 1 || radius > st.cfg.search_geo_max_radius_km { return err(StatusCode::UNPROCESSABLE_ENTITY, "invalid_request", &format!("radius_km must be 1..{}", st.cfg.search_geo_max_radius_km), &r); }
    let pool = match &st.pool { Some(p) => p, None => return err(StatusCode::SERVICE_UNAVAILABLE, "dependency_unavailable", "postgres unavailable", &r) };
    let radius_m = (radius * 1000) as f64;
    let qstr = qp(&m, "q").map(|s| s.as_str()).unwrap_or("");
    let __sp = apm_otlp::dep_span("SELECT shops_view (geo)", "postgresql", SHOPS_SQL);
    let __r = sqlx::query_scalar::<_, Value>(SHOPS_SQL).bind(lat).bind(lng).bind(radius_m).bind(qstr).fetch_one(pool).await;
    apm_otlp::end_dep(__sp);
    match __r {
        Ok(v) => pretty(StatusCode::OK, v),
        Err(_) => err(StatusCode::INTERNAL_SERVER_ERROR, "internal_error", "shops query failed", &r),
    }
}

const TRENDING_SQL: &str = r#"
SELECT json_build_object('items', coalesce(json_agg(json_build_object(
   'product_id',p.product_id,'name_en',p.name_en,'name_bn',p.name_bn,
   'orders',t.cnt,'list_price_minor',p.list_price_minor,'rating_avg',p.rating_avg) ORDER BY t.cnt DESC), '[]'::json)) AS r
FROM (SELECT product_id, sum(order_count) cnt FROM trending_counters
      WHERE bucket_date >= current_date - 7 GROUP BY product_id ORDER BY cnt DESC LIMIT 20) t
JOIN products_view p ON p.product_id = t.product_id AND p.is_active"#;

pub async fn trending(State(st): State<Arc<AppState>>, h: HeaderMap) -> Response {
    let r = rid(&h);
    let pool = match &st.pool { Some(p) => p, None => return err(StatusCode::SERVICE_UNAVAILABLE, "dependency_unavailable", "postgres unavailable", &r) };
    let __sp = apm_otlp::dep_span("SELECT trending", "postgresql", TRENDING_SQL);
    let __r = sqlx::query_scalar::<_, Value>(TRENDING_SQL).fetch_one(pool).await;
    apm_otlp::end_dep(__sp);
    match __r {
        Ok(v) => pretty(StatusCode::OK, v),
        Err(_) => err(StatusCode::INTERNAL_SERVER_ERROR, "internal_error", "trending query failed", &r),
    }
}

const CATEGORIES_SQL: &str = r#"
SELECT json_build_object('tree', coalesce(json_agg(json_build_object(
   'category_id',category_id,'name_en',name_en,'name_bn',name_bn,'slug',slug,'parent_id',parent_id,
   'children', (SELECT coalesce(json_agg(json_build_object('category_id',c.category_id,'name_en',c.name_en,'name_bn',c.name_bn,'slug',c.slug)), '[]'::json)
                FROM categories_view c WHERE c.parent_id = p.category_id AND c.is_active)) ORDER BY sort_order NULLS LAST), '[]'::json)) AS r
FROM categories_view p WHERE parent_id IS NULL AND is_active"#;

pub async fn categories_tree(State(st): State<Arc<AppState>>, h: HeaderMap) -> Response {
    let r = rid(&h);
    let pool = match &st.pool { Some(p) => p, None => return err(StatusCode::SERVICE_UNAVAILABLE, "dependency_unavailable", "postgres unavailable", &r) };
    let __sp = apm_otlp::dep_span("SELECT categories_view", "postgresql", CATEGORIES_SQL);
    let __r = sqlx::query_scalar::<_, Value>(CATEGORIES_SQL).fetch_one(pool).await;
    apm_otlp::end_dep(__sp);
    match __r {
        Ok(v) => pretty(StatusCode::OK, v),
        Err(_) => err(StatusCode::INTERNAL_SERVER_ERROR, "internal_error", "categories query failed", &r),
    }
}

pub async fn admin_reindex(State(st): State<Arc<AppState>>, h: HeaderMap) -> Response {
    let r = rid(&h);
    let bearer = h.get("authorization").and_then(|v| v.to_str().ok());
    match auth::verify(&st.cfg, bearer) {
        Err(_) => err(StatusCode::UNAUTHORIZED, "unauthorized", "missing or invalid token", &r),
        Ok(claims) => {
            if !auth::is_admin(&claims) { return err(StatusCode::FORBIDDEN, "forbidden", "admin role required", &r); }
            let job_id = uuid::Uuid::new_v4().to_string();
            crate::observability::logging::info("search.admin", &format!("reindex accepted job_id={} by={}", job_id, claims.sub.unwrap_or_default()));
            pretty(StatusCode::ACCEPTED, json!({"job_id": job_id, "status": "accepted", "message": "reindex scheduled"}))
        }
    }
}
