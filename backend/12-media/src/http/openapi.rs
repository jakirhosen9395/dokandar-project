//! Hand-built OpenAPI 3.0.3 spec (every served route appears) + the Swagger UI HTML.
//! info.version == code_version so the version cannot lie.
use crate::config::Config;
use serde_json::{json, Value};

pub fn spec(cfg: &Config) -> Value {
    // info.description: identity block + a short How-to-test (media lifecycle), built outside the
    // json! macro to keep the macro literal flat (avoids brace/quote balance traps).
    let desc = format!(
        "**service_name**: `{}` | **code_version**: `{}` | **env_version**: `{}` | **tenant**: `{}` | **env**: `{}`\n\n\
Presigned upload/download URLs, upload lifecycle (pending→uploaded→scanned→ready), AV-scan gating, \
derivatives, access grants. Bytes flow browser↔S3; this service mints URLs + tracks state.\n\n\
### How to test\n\
1. Click **Authorize** and paste a Bearer **access token** from 01-auth \
(`POST /api/v1/auth/login/request` → `/login/verify`). All `/api/v1/media/*` routes require it.\n\
2. `POST /api/v1/media/upload-url` (pick a `scope` + `mime`) → returns a presigned PUT `upload_url` + a `media_id`.\n\
3. `PUT` your bytes to that `upload_url` (out-of-band, browser↔S3), then `POST /api/v1/media/{{id}}/complete` → state becomes `uploaded`.\n\
4. Once `state=ready` (AV-clean + derivatives), `GET /api/v1/media/{{id}}/signed-url?variant=original` mints a presigned GET.\n\
5. `kyc_doc` scope is admin-only on read; grant another user with `POST /api/v1/media/{{id}}/grants`.",
        cfg.service_name, cfg.code_version, cfg.env_version, cfg.tenant, cfg.app_env
    );
    json!({
        "openapi": "3.0.3",
        "info": {
            "title": "DOKANDAR Media Service",
            "description": desc,
            "version": cfg.code_version,
            "contact": {"name": "DOKANDAR Platform", "url": "https://dokandar.com.bd", "email": "api@dokandar.com.bd"},
            "license": {"name": "Proprietary"},
        },
        "servers": [
            {"url": "https://api.dokandar.com.bd", "description": "prod"},
            {"url": "http://localhost:10012", "description": "local"}
        ],
        "tags": [
            {"name": "media", "description": "Presigned upload/download URLs, upload lifecycle, AV-scan gating, derivatives, and access grants."},
            {"name": "ops", "description": "Operational contract endpoints (/ready /health /data /metrics /openapi.json /docs) — no auth."}
        ],
        "components": {
            "securitySchemes": {
                "bearerJwt": {"type": "http", "scheme": "bearer", "bearerFormat": "JWT",
                    "description": "RS256 user JWT minted by 01-auth (verify-only here)."},
                "internalToken": {"type": "apiKey", "in": "header", "name": "x-internal-token",
                    "description": "Shared INTERNAL_SERVICE_TOKEN for the east-west gRPC surface only (not REST)."}
            },
            "schemas": {
                "ErrorEnvelope": {"type": "object", "properties": {"error": {"type": "object", "properties": {
                    "code": {"type": "string", "description": "stable lowercase_snake machine code", "example": "not_found"},
                    "message": {"type": "string", "example": "media not found"},
                    "request_id": {"type": "string", "description": "honour-or-mint x-request-id", "example": "a1b2c3d4e5f6"},
                    "details": {"type": "object", "nullable": true}
                }}}},
                "MediaInfo": {"type": "object", "properties": {
                    "media_id": {"type": "string", "format": "uuid"},
                    "owner_id": {"type": "string", "format": "uuid"},
                    "scope": {"type": "string"},
                    "kind": {"type": "string"},
                    "mime": {"type": "string"},
                    "bytes": {"type": "integer", "format": "int64"},
                    "state": {"type": "string", "enum": ["pending","uploaded","scanned","ready","quarantined","deleted"]},
                    "av_clean": {"type": "boolean"},
                    "derivatives_ready": {"type": "boolean"},
                    "object_key": {"type": "string"}
                }},
                "UploadUrlRequest": {"type": "object", "required": ["scope","mime"], "properties": {
                    "scope": {"type": "string", "description": "upload purpose; selects bucket/prefix + access policy", "enum": ["profile_avatar","shop_logo","shop_banner","product_image","review_photo","kyc_doc","pod_photo","generic"]},
                    "kind": {"type": "string", "description": "optional sub-kind hint for derivative generation"},
                    "mime": {"type": "string", "description": "declared content type (validated on complete)", "example": "image/jpeg"},
                    "max_bytes": {"type": "integer", "format": "int64", "description": "optional caller-requested size cap (bytes); server may clamp"}
                }, "example": {"scope": "product_image", "mime": "image/jpeg", "max_bytes": 5242880}},
                "UploadUrlResponse": {"type": "object", "properties": {
                    "media_id": {"type": "string"}, "upload_url": {"type": "string"},
                    "method": {"type": "string"}, "content_type": {"type": "string"},
                    "object_key": {"type": "string"}, "max_bytes": {"type": "integer"},
                    "expires_at": {"type": "integer", "format": "int64"}
                }},
                "CompleteRequest": {"type": "object", "properties": {
                    "sha256": {"type": "string", "description": "optional client-computed hex SHA-256 of the uploaded bytes"},
                    "bytes": {"type": "integer", "format": "int64", "description": "optional client-observed object size in bytes"}
                }, "example": {"sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "bytes": 204800}},
                "SignedUrlResponse": {"type": "object", "properties": {
                    "signed_url": {"type": "string"}, "variant": {"type": "string"},
                    "expires_at": {"type": "integer", "format": "int64"}
                }},
                "GrantRequest": {"type": "object", "required": ["grantee_id"], "properties": {
                    "grantee_id": {"type": "string", "format": "uuid", "description": "user id to grant read access to this media object"}
                }, "example": {"grantee_id": "11111111-1111-4111-8111-111111111111"}}
            }
        },
        "security": [{"bearerJwt": []}],
        "paths": {
            "/api/v1/media/upload-url": {"post": {
                "operationId": "createUploadUrl",
                "summary": "Issue a presigned PUT upload URL + a pending media row",
                "description": "Creates a `pending` media row and returns a short-lived presigned S3 PUT URL the client uploads bytes to directly. Call `/complete` afterward to confirm.",
                "tags": ["media"], "security": [{"bearerJwt": []}],
                "requestBody": {"required": true, "content": {"application/json": {"schema": {"$ref": "#/components/schemas/UploadUrlRequest"}}}},
                "responses": {
                    "200": {"description": "issued", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/UploadUrlResponse"}}}},
                    "401": {"description": "missing/invalid token", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}},
                    "422": {"description": "validation", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}},
                    "500": {"description": "internal error", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}}
                }
            }},
            "/api/v1/media/{id}/complete": {"post": {
                "operationId": "completeUpload",
                "summary": "Confirm an upload landed (HeadObject) → state=uploaded",
                "description": "Owner confirms the bytes landed in S3. The service HeadObjects the key and advances the row to `uploaded`, queueing AV-scan + derivative work.",
                "tags": ["media"], "security": [{"bearerJwt": []}],
                "parameters": [{"name": "id", "in": "path", "required": true, "description": "media id", "schema": {"type": "string", "format": "uuid"}}],
                "requestBody": {"content": {"application/json": {"schema": {"$ref": "#/components/schemas/CompleteRequest"}}}},
                "responses": {
                    "200": {"description": "confirmed", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/MediaInfo"}}}},
                    "401": {"description": "missing/invalid token", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}},
                    "403": {"description": "not owner", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}},
                    "404": {"description": "not found", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}},
                    "409": {"description": "not arrived / state conflict", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}}
                }
            }},
            "/api/v1/media/{id}": {
                "get": {
                    "operationId": "getMedia",
                    "summary": "Media metadata + lifecycle state",
                    "description": "Returns the media row (owner, scope, mime, bytes, lifecycle state, AV/derivative flags). Does not return bytes — use `/signed-url`.",
                    "tags": ["media"], "security": [{"bearerJwt": []}],
                    "parameters": [{"name": "id", "in": "path", "required": true, "description": "media id", "schema": {"type": "string", "format": "uuid"}}],
                    "responses": {
                        "200": {"description": "ok", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/MediaInfo"}}}},
                        "401": {"description": "missing/invalid token", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}},
                        "404": {"description": "not found", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}}
                    }
                },
                "delete": {
                    "operationId": "deleteMedia",
                    "summary": "Soft-delete (owner or admin) → emits media.deleted",
                    "description": "Soft-deletes the object (state=`deleted`) and emits `media.deleted` via the transactional outbox. Owner or admin only.",
                    "tags": ["media"], "security": [{"bearerJwt": []}],
                    "parameters": [{"name": "id", "in": "path", "required": true, "description": "media id", "schema": {"type": "string", "format": "uuid"}}],
                    "responses": {
                        "200": {"description": "deleted"},
                        "401": {"description": "missing/invalid token", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}},
                        "403": {"description": "forbidden", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}},
                        "404": {"description": "not found", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}}
                    }
                }
            },
            "/api/v1/media/{id}/signed-url": {"get": {
                "operationId": "getSignedUrl",
                "summary": "Presigned GET download URL per variant (authorized; object must be ready)",
                "description": "Mints a short-lived presigned S3 GET URL for the requested variant. Caller must be owner or grantee (`kyc_doc` is admin-only); the object must be in `ready` state.",
                "tags": ["media"], "security": [{"bearerJwt": []}],
                "parameters": [
                    {"name": "id", "in": "path", "required": true, "description": "media id", "schema": {"type": "string", "format": "uuid"}},
                    {"name": "variant", "in": "query", "required": false, "description": "derivative variant to sign", "schema": {"type": "string", "enum": ["original","thumb","medium","large"], "default": "original"}}
                ],
                "responses": {
                    "200": {"description": "signed", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/SignedUrlResponse"}}}},
                    "401": {"description": "missing/invalid token", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}},
                    "403": {"description": "forbidden (not owner/grantee; kyc_doc admin-only)", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}},
                    "404": {"description": "not found", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}},
                    "409": {"description": "not ready", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}}
                }
            }},
            "/api/v1/media": {"get": {
                "operationId": "listMedia",
                "summary": "List the caller's own media objects",
                "description": "Lists media objects owned by the authenticated caller, optionally filtered by `scope` and/or lifecycle `state`.",
                "tags": ["media"], "security": [{"bearerJwt": []}],
                "parameters": [
                    {"name": "scope", "in": "query", "required": false, "description": "filter by upload scope", "schema": {"type": "string", "enum": ["profile_avatar","shop_logo","shop_banner","product_image","review_photo","kyc_doc","pod_photo","generic"]}},
                    {"name": "state", "in": "query", "required": false, "description": "filter by lifecycle state", "schema": {"type": "string", "enum": ["pending","uploaded","scanned","ready","quarantined","deleted"]}}
                ],
                "responses": {
                    "200": {"description": "list", "content": {"application/json": {"schema": {"type": "object", "properties": {"items": {"type": "array", "items": {"$ref": "#/components/schemas/MediaInfo"}}, "count": {"type": "integer"}}}}}},
                    "401": {"description": "missing/invalid token", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}}
                }
            }},
            "/api/v1/media/{id}/grants": {"post": {
                "operationId": "createGrant",
                "summary": "Grant another user read access to a media object",
                "description": "Owner grants another user read (signed-url) access to this object. Idempotent per (media, grantee).",
                "tags": ["media"], "security": [{"bearerJwt": []}],
                "parameters": [{"name": "id", "in": "path", "required": true, "description": "media id", "schema": {"type": "string", "format": "uuid"}}],
                "requestBody": {"required": true, "content": {"application/json": {"schema": {"$ref": "#/components/schemas/GrantRequest"}}}},
                "responses": {
                    "200": {"description": "granted"},
                    "401": {"description": "missing/invalid token", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}},
                    "403": {"description": "not owner", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}},
                    "404": {"description": "not found", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}},
                    "422": {"description": "validation", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}}
                }
            }},
            "/ready": {"get": {"operationId": "getReady", "summary": "Readiness gate (postgres + s3)", "description": "200 only when Postgres AND S3 are reachable (presign cannot serve without the object store).", "tags": ["ops"], "security": [], "responses": {"200": {"description": "ready"}, "503": {"description": "not ready"}}}},
            "/health": {"get": {"operationId": "getHealth", "summary": "Full diagnostics + observability block", "description": "Full dependency diagnostics + an observability block. Only Postgres + S3 flip status; kafka/es/mongo are diagnostic-only.", "tags": ["ops"], "security": [], "responses": {"200": {"description": "healthy"}, "503": {"description": "unhealthy"}}}},
            "/data": {"get": {"operationId": "getData", "summary": "Identity + the data/<tenant>/result.json snapshot", "description": "Identity block prepended to the read-only data/<tenant>/result.json snapshot.", "tags": ["ops"], "security": [], "responses": {"200": {"description": "snapshot"}, "404": {"description": "no_snapshot", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}}}}},
            "/metrics": {"get": {"operationId": "getMetrics", "summary": "Prometheus metrics", "description": "Prometheus text exposition (the one non-JSON endpoint).", "tags": ["ops"], "security": [], "responses": {"200": {"description": "prometheus text"}}}},
            "/openapi.json": {"get": {"operationId": "getOpenapi", "summary": "This document", "description": "The hand-built OpenAPI 3.0.3 document for this service.", "tags": ["ops"], "security": [], "responses": {"200": {"description": "openapi"}}}},
            "/docs": {"get": {"operationId": "getDocs", "summary": "Swagger UI", "description": "Swagger UI HTML page rendering this document.", "tags": ["ops"], "security": [], "responses": {"200": {"description": "html"}}}}
        }
    })
}

pub const SWAGGER_HTML: &str = r#"<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>12-media API</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui.css">
</head>
<body>
  <div id="swagger-ui"></div>
  <script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
  <script>
    window.ui = SwaggerUIBundle({ url: '/openapi.json', dom_id: '#swagger-ui', deepLinking: true, persistAuthorization: true });
  </script>
</body>
</html>"#;
