//! The 7 business routes (all AuthUser-guarded). Each maps the domain result/MediaError to the
//! pretty-JSON envelope. Presigned URLs are returned to the client but NEVER logged.
use crate::auth::AuthUser;
use crate::domain::{self, MediaError, MediaInfo};
use crate::http::ops::{err, pretty, req_id};
use crate::http::AppState;
use actix_web::{web, HttpRequest, HttpResponse};
use serde::Deserialize;
use serde_json::json;

fn map_media_err(e: MediaError, rid: &str) -> HttpResponse {
    let (status, code) = e.parts();
    err(status, code, &e.message(), rid)
}

fn info_json(i: &MediaInfo) -> serde_json::Value {
    json!({
        "media_id": i.media_id,
        "owner_id": i.owner_id,
        "scope": i.scope,
        "kind": i.kind,
        "mime": i.mime,
        "bytes": i.bytes,
        "state": i.state,
        "av_clean": i.av_clean,
        "derivatives_ready": i.derivatives_ready,
        "object_key": i.object_key,
    })
}

/// Both pool + s3 must be present; returns the 503 envelope otherwise.
macro_rules! deps {
    ($st:expr, $rid:expr) => {{
        match (&$st.pool, &$st.s3) {
            (Some(p), Some(s)) => (p, s),
            _ => {
                return err(503, "dependencies_unavailable", "postgres/s3 not ready", &$rid)
            }
        }
    }};
}

#[derive(Deserialize)]
pub struct UploadReq {
    pub scope: String,
    #[serde(default)]
    pub kind: Option<String>,
    pub mime: String,
    #[serde(default)]
    pub max_bytes: Option<i64>,
}

/// POST /api/v1/media/upload-url
pub async fn upload_url(
    st: web::Data<AppState>,
    req: HttpRequest,
    user: AuthUser,
    body: web::Json<UploadReq>,
) -> HttpResponse {
    let rid = req_id(&req);
    let (pool, s3) = deps!(st, rid);
    let kind = body.kind.clone().unwrap_or_else(|| "generic".into());
    let max_bytes = body.max_bytes.unwrap_or(10 * 1024 * 1024);
    match domain::issue_upload(
        pool,
        s3,
        &st.cfg,
        user.id(),
        &body.scope,
        &kind,
        &body.mime,
        max_bytes,
    )
    .await
    {
        Ok(r) => {
            // in-request log (carries trace.id via the active OTel context) — never log the presigned URL
            crate::observability::logging::info(
                "media.api",
                &format!("upload-url issued media_id={} scope={}", r.media_id, body.scope),
            );
            pretty(
                200,
                json!({
                    "media_id": r.media_id,
                    "upload_url": r.upload_url,
                    "method": r.method,
                    "content_type": r.content_type,
                    "object_key": r.object_key,
                    "max_bytes": r.max_bytes,
                    "expires_at": r.expires_at,
                }),
            )
        }
        Err(e) => map_media_err(e, &rid),
    }
}

#[derive(Deserialize)]
pub struct CompleteReq {
    #[serde(default)]
    pub sha256: Option<String>,
    #[serde(default)]
    pub bytes: Option<i64>,
}

/// POST /api/v1/media/{id}/complete
pub async fn complete(
    st: web::Data<AppState>,
    req: HttpRequest,
    user: AuthUser,
    path: web::Path<String>,
    body: web::Json<CompleteReq>,
) -> HttpResponse {
    let rid = req_id(&req);
    let (pool, s3) = deps!(st, rid);
    let id = path.into_inner();
    let sha = body.sha256.clone().unwrap_or_default();
    let bytes = body.bytes.unwrap_or(0);
    match domain::complete(pool, s3, &id, user.id(), &sha, bytes).await {
        Ok(i) => pretty(200, info_json(&i)),
        Err(e) => map_media_err(e, &rid),
    }
}

/// GET /api/v1/media/{id}
pub async fn get_one(
    st: web::Data<AppState>,
    req: HttpRequest,
    _user: AuthUser,
    path: web::Path<String>,
) -> HttpResponse {
    let rid = req_id(&req);
    let pool = match &st.pool {
        Some(p) => p,
        None => return err(503, "dependencies_unavailable", "postgres not ready", &rid),
    };
    match domain::get_media(pool, &path.into_inner()).await {
        Ok(i) => pretty(200, info_json(&i)),
        Err(e) => map_media_err(e, &rid),
    }
}

#[derive(Deserialize)]
pub struct SignedQuery {
    #[serde(default)]
    pub variant: Option<String>,
}

/// GET /api/v1/media/{id}/signed-url?variant=
pub async fn signed_url(
    st: web::Data<AppState>,
    req: HttpRequest,
    user: AuthUser,
    path: web::Path<String>,
    q: web::Query<SignedQuery>,
) -> HttpResponse {
    let rid = req_id(&req);
    let (pool, s3) = deps!(st, rid);
    let variant = q.variant.clone().unwrap_or_else(|| "original".into());
    match domain::signed_url(
        pool,
        s3,
        &st.cfg,
        &path.into_inner(),
        &variant,
        user.id(),
        &user.claims.role_str(),
    )
    .await
    {
        Ok(r) => {
            crate::observability::logging::info(
                "media.api",
                &format!("signed-url issued variant={}", r.variant),
            );
            pretty(
                200,
                json!({"signed_url": r.signed_url, "variant": r.variant, "expires_at": r.expires_at}),
            )
        }
        Err(e) => map_media_err(e, &rid),
    }
}

#[derive(Deserialize)]
pub struct ListQuery {
    #[serde(default)]
    pub scope: Option<String>,
    #[serde(default)]
    pub state: Option<String>,
}

/// GET /api/v1/media — list the caller's own objects.
pub async fn list_mine(
    st: web::Data<AppState>,
    req: HttpRequest,
    user: AuthUser,
    q: web::Query<ListQuery>,
) -> HttpResponse {
    let rid = req_id(&req);
    let pool = match &st.pool {
        Some(p) => p,
        None => return err(503, "dependencies_unavailable", "postgres not ready", &rid),
    };
    match domain::list_mine(pool, user.id(), q.scope.as_deref(), q.state.as_deref()).await {
        Ok(list) => {
            let items: Vec<_> = list.iter().map(info_json).collect();
            pretty(200, json!({"items": items, "count": items.len()}))
        }
        Err(e) => map_media_err(e, &rid),
    }
}

#[derive(Deserialize)]
pub struct GrantReq {
    pub grantee_id: String,
}

/// POST /api/v1/media/{id}/grants
pub async fn grant(
    st: web::Data<AppState>,
    req: HttpRequest,
    user: AuthUser,
    path: web::Path<String>,
    body: web::Json<GrantReq>,
) -> HttpResponse {
    let rid = req_id(&req);
    let pool = match &st.pool {
        Some(p) => p,
        None => return err(503, "dependencies_unavailable", "postgres not ready", &rid),
    };
    let id = path.into_inner();
    match domain::grant(pool, &id, user.id(), &body.grantee_id).await {
        Ok(_) => pretty(
            200,
            json!({"media_id": id, "grantee_id": body.grantee_id, "granted": true}),
        ),
        Err(e) => map_media_err(e, &rid),
    }
}

/// DELETE /api/v1/media/{id} — owner or admin soft-delete.
pub async fn delete_one(
    st: web::Data<AppState>,
    req: HttpRequest,
    user: AuthUser,
    path: web::Path<String>,
) -> HttpResponse {
    let rid = req_id(&req);
    let pool = match &st.pool {
        Some(p) => p,
        None => return err(503, "dependencies_unavailable", "postgres not ready", &rid),
    };
    let id = path.into_inner();
    match domain::soft_delete(pool, &st.cfg, &id, user.id(), &user.claims.role_str()).await {
        Ok(_) => pretty(200, json!({"media_id": id, "deleted": true})),
        Err(e) => map_media_err(e, &rid),
    }
}
