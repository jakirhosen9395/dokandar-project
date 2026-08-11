//! Hand-built OpenAPI 3.0.3 + Swagger UI (mirrors 03-seller's depth: segmented tags,
//! typed component schemas, documented parameters/responses, $ref envelopes).
use crate::config::Config;
use serde_json::{json, Value};

fn ref_(name: &str) -> Value { json!({ "$ref": format!("#/components/schemas/{name}") }) }
fn json_resp(desc: &str, schema: &str) -> Value {
    json!({ "description": desc, "content": { "application/json": { "schema": ref_(schema) } } })
}

pub fn spec(cfg: &Config) -> Value {
    json!({
        "openapi": "3.0.3",
        "info": {
            "title": "DOKANDAR Search Service",
            "version": cfg.code_version,
            "description": format!(
                "**service_name**: `{}` &nbsp;|&nbsp; **code_version**: `{}` &nbsp;|&nbsp; **env_version**: `{}` &nbsp;|&nbsp; **tenant**: `{}` &nbsp;|&nbsp; **env**: `{}`\n\n\
**Discovery (CQRS read projection).** Consume-only Kafka projectors hydrate the PostgreSQL `*_view` store (+ Elasticsearch `:9201`); public reads on `/api/v1/search/*`, admin reindex behind RS256. Bilingual (Bangla/English) full-text + trigram + geo. Responses are pretty-printed JSON; errors use the standard `{{error:{{code,message,request_id,details}}}}` envelope.\n\n\
### How to test\n\
1. The discovery reads (`GET /api/v1/search/products`, `/autocomplete`, `/shops`, `/trending`, `/categories/tree`) are **public** — no token needed.\n\
2. Only `POST /api/v1/search/admin/reindex` is protected: click **Authorize** and paste a Bearer **access token** with the `admin` role minted by 01-auth (`POST /api/v1/auth/login/request` → `/login/verify`). A non-admin token returns `403`, a missing/invalid token `401`.\n\
3. `products` supports `q`, `locale` (en|bn), `category_id`, `page`, `size`; `shops` requires `lat`+`lng`. Out-of-range params return `422 invalid_request`.",
                cfg.service_name, cfg.code_version, cfg.env_version, cfg.tenant, cfg.app_env
            ),
            "contact": { "name": "DOKANDAR Platform", "url": "https://dokandar.com.bd", "email": "api@dokandar.com.bd" },
            "license": { "name": "Proprietary" }
        },
        "servers": [
            { "url": "https://api.dokandar.com.bd", "description": "prod" },
            { "url": "http://localhost:10005", "description": "local" }
        ],
        "tags": [
            { "name": "ops", "description": "Operational contract — readiness, health, data snapshot, metrics." },
            { "name": "products", "description": "Product discovery — bilingual full-text search, facets, autocomplete." },
            { "name": "shops", "description": "Shop discovery — geo radius (earthdistance) search." },
            { "name": "discovery", "description": "Trending products and the category tree." },
            { "name": "admin", "description": "Administrative operations (RS256, admin role required)." }
        ],
        "paths": {
            "/ready": { "get": { "operationId": "getReady", "tags": ["ops"], "summary": "Readiness probe", "description": "200 iff PostgreSQL (the read model) is reachable; the LB gates on this. ES/Kafka/Mongo/APM do NOT gate (search degrades to the PG tsvector fallback).", "responses": {
                "200": json_resp("ready", "ReadyResponse"), "503": json_resp("not ready", "ReadyResponse") } } },
            "/health": { "get": { "operationId": "getHealth", "tags": ["ops"], "summary": "Liveness + every dependency's health", "description": "Full diagnostics across postgres, the business-search ES (:9201), the log-sink ES (:9200), kafka, mongo, apm, plus the projection row counts.", "responses": {
                "200": json_resp("healthy", "HealthResponse"), "503": json_resp("unhealthy", "HealthResponse") } } },
            "/data": { "get": { "operationId": "getData", "tags": ["ops"], "summary": "Tenant data snapshot", "description": "The identity block prepended to the read-only `data/<tenant>/result.json` snapshot.", "responses": {
                "200": { "description": "snapshot" }, "404": json_resp("no snapshot", "ErrorEnvelope"), "500": json_resp("snapshot not an object", "ErrorEnvelope") } } },
            "/metrics": { "get": { "operationId": "getMetrics", "tags": ["ops"], "summary": "Prometheus exposition", "description": "RED metrics + `search_view_rows` + `search_projection_lag_messages`.", "responses": { "200": { "description": "text/plain; version=0.0.4" } } } },
            "/api/v1/search/products": { "get": { "operationId": "searchProducts", "tags": ["products"], "summary": "Product search", "description": "Bilingual full-text (tsvector) + trigram fallback, category filter, price-ordered, with category facets and pagination.", "parameters": [
                { "name": "q", "in": "query", "description": "search terms (English/Bangla)", "schema": { "type": "string" }, "example": "rice" },
                { "name": "locale", "in": "query", "description": "result locale; one of en|bn", "schema": { "type": "string", "enum": ["en", "bn"], "default": "en" } },
                { "name": "category_id", "in": "query", "description": "filter by category UUID", "schema": { "type": "string", "format": "uuid" } },
                { "name": "page", "in": "query", "description": "1-based page", "schema": { "type": "integer", "minimum": 1, "default": 1 } },
                { "name": "size", "in": "query", "description": "page size (1..100)", "schema": { "type": "integer", "minimum": 1, "maximum": 100, "default": 20 } }
            ], "responses": { "200": json_resp("results + facets", "ProductSearchResponse"), "422": json_resp("invalid_request (locale/size/category_id)", "ErrorEnvelope") } } },
            "/api/v1/search/autocomplete": { "get": { "operationId": "autocompleteProducts", "tags": ["products"], "summary": "Autocomplete suggestions", "description": "Trigram similarity over product names; returns up to 10 suggestions.", "parameters": [
                { "name": "q", "in": "query", "required": true, "description": "prefix/partial term", "schema": { "type": "string" }, "example": "ri" },
                { "name": "locale", "in": "query", "schema": { "type": "string", "enum": ["en", "bn"], "default": "en" } }
            ], "responses": { "200": json_resp("suggestions", "AutocompleteResponse"), "422": json_resp("q required / bad locale", "ErrorEnvelope") } } },
            "/api/v1/search/shops": { "get": { "operationId": "searchShops", "tags": ["shops"], "summary": "Nearby shops", "description": "Geo radius search via PostgreSQL earthdistance; ordered by distance.", "parameters": [
                { "name": "lat", "in": "query", "required": true, "description": "latitude (-90..90)", "schema": { "type": "number", "format": "double" }, "example": 23.8103 },
                { "name": "lng", "in": "query", "required": true, "description": "longitude (-180..180)", "schema": { "type": "number", "format": "double" }, "example": 90.4125 },
                { "name": "radius_km", "in": "query", "description": "search radius (1..30)", "schema": { "type": "integer", "minimum": 1, "maximum": 30, "default": 5 } },
                { "name": "q", "in": "query", "description": "optional name filter", "schema": { "type": "string" } }
            ], "responses": { "200": json_resp("shops by distance", "ShopSearchResponse"), "422": json_resp("lat/lng required or out of range", "ErrorEnvelope") } } },
            "/api/v1/search/trending": { "get": { "operationId": "getTrending", "tags": ["discovery"], "summary": "Trending products", "description": "Top products by order volume over the trailing 7 days.", "responses": { "200": json_resp("trending items", "TrendingResponse") } } },
            "/api/v1/search/categories/tree": { "get": { "operationId": "getCategoryTree", "tags": ["discovery"], "summary": "Category tree", "description": "Active categories as a 2-level tree (roots + children).", "responses": { "200": json_resp("category tree", "CategoryTreeResponse") } } },
            "/api/v1/search/admin/reindex": { "post": { "operationId": "reindexSearch", "tags": ["admin"], "summary": "Admin reindex", "description": "Schedules a re-projection. Requires a valid RS256 token with the admin role.", "security": [{ "bearerJwt": [] }], "responses": {
                "202": json_resp("accepted", "ReindexResponse"), "401": json_resp("missing/invalid token", "ErrorEnvelope"), "403": json_resp("not an admin", "ErrorEnvelope") } } }
        },
        "components": {
            "securitySchemes": { "bearerJwt": { "type": "http", "scheme": "bearer", "bearerFormat": "JWT", "description": "RS256 access token minted by 01-auth." } },
            "schemas": {
                "Identity": { "type": "object", "properties": {
                    "service_name": { "type": "string", "example": "05-search" }, "code_version": { "type": "string" },
                    "env_version": { "type": "string" }, "tenant": { "type": "string", "enum": ["local", "cloud"] },
                    "env": { "type": "string" }, "uptime_seconds": { "type": "integer" } } },
                "ErrorEnvelope": { "type": "object", "properties": { "error": { "type": "object", "properties": {
                    "code": { "type": "string", "example": "invalid_request" }, "message": { "type": "string" },
                    "request_id": { "type": "string" }, "details": { "type": "object", "additionalProperties": true } } } } },
                "Dependency": { "type": "object", "properties": { "name": { "type": "string" }, "reachable": { "type": "boolean" }, "latency_ms": { "type": "number" }, "detail": { "type": "string" } } },
                "ReadyResponse": { "type": "object", "properties": { "status": { "type": "string", "enum": ["ready", "not_ready"] }, "identity": ref_("Identity"), "dependencies": { "type": "array", "items": ref_("Dependency") } } },
                "Check": { "type": "object", "properties": { "ok": { "type": "boolean" }, "latency_ms": { "type": "number" }, "detail": { "type": "string" } } },
                "HealthResponse": { "type": "object", "properties": {
                    "status": { "type": "string", "enum": ["healthy", "unhealthy"] }, "identity": ref_("Identity"),
                    "checks": { "type": "object", "properties": { "postgres": ref_("Check"), "elasticsearch": ref_("Check"), "log_elasticsearch": ref_("Check"), "kafka": ref_("Check"), "mongo_logs": ref_("Check"), "apm": ref_("Check") } },
                    "projection": { "type": "object", "properties": { "products_view": { "type": "integer" }, "shops_view": { "type": "integer" }, "categories_view": { "type": "integer" } } },
                    "observability": { "type": "object", "properties": { "apm_service_name": { "type": "string" }, "logs_sink_es": { "type": "string" }, "logs_sink_mongo": { "type": "string" }, "search_es": { "type": "string" } } } } },
                "ProductItem": { "type": "object", "properties": {
                    "product_id": { "type": "string", "format": "uuid" }, "shop_id": { "type": "string", "format": "uuid", "nullable": true },
                    "category_id": { "type": "string", "format": "uuid", "nullable": true }, "name_en": { "type": "string" }, "name_bn": { "type": "string" },
                    "slug": { "type": "string", "nullable": true }, "list_price_minor": { "type": "integer", "description": "price in paisa" },
                    "sale_price_minor": { "type": "integer", "nullable": true }, "rating_avg": { "type": "number" }, "rating_count": { "type": "integer" }, "in_stock": { "type": "boolean" } } },
                "Facets": { "type": "object", "properties": { "category": { "type": "object", "additionalProperties": { "type": "integer" }, "description": "category_id → count" } } },
                "ProductSearchResponse": { "type": "object", "properties": {
                    "total": { "type": "integer" }, "page": { "type": "integer" }, "size": { "type": "integer" }, "locale": { "type": "string" },
                    "items": { "type": "array", "items": ref_("ProductItem") }, "facets": ref_("Facets") } },
                "Suggestion": { "type": "object", "properties": { "text": { "type": "string" }, "product_id": { "type": "string", "format": "uuid" } } },
                "AutocompleteResponse": { "type": "object", "properties": { "suggestions": { "type": "array", "items": ref_("Suggestion") } } },
                "ShopItem": { "type": "object", "properties": {
                    "shop_id": { "type": "string", "format": "uuid" }, "handle": { "type": "string" }, "name_en": { "type": "string" }, "name_bn": { "type": "string" },
                    "lat": { "type": "number" }, "lng": { "type": "number" }, "distance_km": { "type": "number" }, "rating_avg": { "type": "number" }, "rating_count": { "type": "integer" }, "open_now": { "type": "boolean" } } },
                "ShopSearchResponse": { "type": "object", "properties": { "total": { "type": "integer" }, "items": { "type": "array", "items": ref_("ShopItem") } } },
                "TrendingItem": { "type": "object", "properties": { "product_id": { "type": "string", "format": "uuid" }, "name_en": { "type": "string" }, "name_bn": { "type": "string" }, "orders": { "type": "integer" }, "list_price_minor": { "type": "integer" }, "rating_avg": { "type": "number" } } },
                "TrendingResponse": { "type": "object", "properties": { "items": { "type": "array", "items": ref_("TrendingItem") } } },
                "CategoryChild": { "type": "object", "properties": { "category_id": { "type": "string", "format": "uuid" }, "name_en": { "type": "string" }, "name_bn": { "type": "string" }, "slug": { "type": "string", "nullable": true } } },
                "CategoryNode": { "type": "object", "properties": { "category_id": { "type": "string", "format": "uuid" }, "name_en": { "type": "string" }, "name_bn": { "type": "string" }, "slug": { "type": "string", "nullable": true }, "parent_id": { "type": "string", "format": "uuid", "nullable": true }, "children": { "type": "array", "items": ref_("CategoryChild") } } },
                "CategoryTreeResponse": { "type": "object", "properties": { "tree": { "type": "array", "items": ref_("CategoryNode") } } },
                "ReindexResponse": { "type": "object", "properties": { "job_id": { "type": "string", "format": "uuid" }, "status": { "type": "string", "example": "accepted" }, "message": { "type": "string" } } }
            }
        }
    })
}

pub const SWAGGER_HTML: &str = r##"<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>05-search API</title><link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css"></head><body><div id="swagger-ui"></div><script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script><script>window.ui=SwaggerUIBundle({url:"/openapi.json",dom_id:"#swagger-ui",deepLinking:true,tryItOutEnabled:true,docExpansion:"list",defaultModelsExpandDepth:2,persistAuthorization:true});</script></body></html>"##;
