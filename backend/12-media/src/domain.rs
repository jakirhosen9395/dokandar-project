//! Media domain logic on the PgPool (runtime sqlx; cross-service ids are opaque, no FKs across
//! boundaries). The upload lifecycle: pending → uploaded → (worker) scanned → ready, plus the
//! presigned-URL mint/authz and the soft-delete + outbox emit. All DB calls are wrapped in an
//! OTel dep_span(system="postgresql"). Presigned URLs are NEVER logged.
use crate::config::Config;
use crate::observability::{metrics, otel};
use crate::s3::S3;
use chrono::Utc;
use serde::Serialize;
use serde_json::json;
use sqlx::postgres::PgPool;
use sqlx::Row;
use uuid::Uuid;

/// Scopes that are sensitive: only the owner or an admin may read/sign them.
const ADMIN_ONLY_SCOPES: &[&str] = &["kyc_doc"];
const VALID_SCOPES: &[&str] = &[
    "profile_avatar", "shop_logo", "shop_banner", "product_image",
    "review_photo", "kyc_doc", "pod_photo", "generic",
];
const VALID_VARIANTS: &[&str] = &["original", "thumb", "medium", "large"];

#[derive(Debug)]
pub enum MediaError {
    NotFound,
    Forbidden,
    NotReady,
    Conflict(String),
    Validation(String),
    Storage(String),
    Db(String),
}

impl MediaError {
    /// Map to (http_status, machine_code).
    pub fn parts(&self) -> (u16, &'static str) {
        match self {
            MediaError::NotFound => (404, "media_not_found"),
            MediaError::Forbidden => (403, "forbidden"),
            MediaError::NotReady => (409, "not_ready"),
            MediaError::Conflict(_) => (409, "conflict"),
            MediaError::Validation(_) => (422, "validation_error"),
            MediaError::Storage(_) => (502, "object_store_error"),
            MediaError::Db(_) => (500, "internal_error"),
        }
    }
    pub fn message(&self) -> String {
        match self {
            MediaError::NotFound => "media object not found".into(),
            MediaError::Forbidden => "not authorized for this media object".into(),
            MediaError::NotReady => "media object is not ready (still scanning/processing)".into(),
            MediaError::Conflict(m) => m.clone(),
            MediaError::Validation(m) => m.clone(),
            MediaError::Storage(m) => m.clone(),
            MediaError::Db(m) => m.clone(),
        }
    }
}

impl From<sqlx::Error> for MediaError {
    fn from(e: sqlx::Error) -> Self {
        MediaError::Db(e.to_string())
    }
}

/// Public read model for a media object (mirrors the proto MediaInfo + a few REST extras).
#[derive(Debug, Clone, Serialize)]
pub struct MediaInfo {
    pub media_id: String,
    pub owner_id: String,
    pub scope: String,
    pub kind: String,
    pub mime: String,
    pub bytes: i64,
    pub state: String,
    pub av_clean: bool,
    pub derivatives_ready: bool,
    pub object_key: String,
}

fn dep<'a>(stmt: &'a str) -> Option<opentelemetry::global::BoxedSpan> {
    otel::dep_span("query", "postgresql", stmt)
}

async fn row_to_info(pool: &PgPool, media_id: Uuid) -> Result<Option<MediaInfo>, MediaError> {
    let sp = dep("SELECT media_objects by id");
    let row = sqlx::query(
        "SELECT id, owner_id, scope, kind, mime, COALESCE(bytes,0) AS bytes, state, \
         COALESCE(av_clean,false) AS av_clean, derivatives_ready, object_key \
         FROM media_objects WHERE id = $1 AND state <> 'deleted'",
    )
    .bind(media_id)
    .fetch_optional(pool)
    .await;
    otel::end_dep(sp);
    let row = row?;
    Ok(row.map(|r| MediaInfo {
        media_id: r.get::<Uuid, _>("id").to_string(),
        owner_id: r.get::<Uuid, _>("owner_id").to_string(),
        scope: r.get::<String, _>("scope"),
        kind: r.get::<String, _>("kind"),
        mime: r.get::<String, _>("mime"),
        bytes: r.get::<i64, _>("bytes"),
        state: r.get::<String, _>("state"),
        av_clean: r.get::<bool, _>("av_clean"),
        derivatives_ready: r.get::<bool, _>("derivatives_ready"),
        object_key: r.get::<String, _>("object_key"),
    }))
}

/// The full upload-url result returned to REST/gRPC callers.
pub struct IssueResult {
    pub media_id: String,
    pub upload_url: String,
    pub method: &'static str,
    pub content_type: String,
    pub max_bytes: i64,
    pub object_key: String,
    pub expires_at: i64,
}

/// POST /upload-url — INSERT a pending row + presign a PUT. object_key = original/<scope>/<media_id>.
pub async fn issue_upload(
    pool: &PgPool,
    s3: &S3,
    cfg: &Config,
    owner_id: &str,
    scope: &str,
    kind: &str,
    mime: &str,
    max_bytes: i64,
) -> Result<IssueResult, MediaError> {
    let owner = Uuid::parse_str(owner_id)
        .map_err(|_| MediaError::Validation("owner_id is not a valid uuid".into()))?;
    if !VALID_SCOPES.contains(&scope) {
        return Err(MediaError::Validation(format!("invalid scope: {scope}")));
    }
    if mime.trim().is_empty() {
        return Err(MediaError::Validation("mime is required".into()));
    }
    if max_bytes <= 0 {
        return Err(MediaError::Validation("max_bytes must be > 0".into()));
    }
    let kind = if kind.trim().is_empty() { "generic" } else { kind };
    let media_id = Uuid::new_v4();
    let object_key = format!("original/{}/{}", scope, media_id);

    let sp = dep("INSERT media_objects (pending)");
    let r = sqlx::query(
        "INSERT INTO media_objects (id, owner_id, scope, kind, mime, bucket, object_key, state) \
         VALUES ($1,$2,$3,$4,$5,$6,$7,'pending')",
    )
    .bind(media_id)
    .bind(owner)
    .bind(scope)
    .bind(kind)
    .bind(mime)
    .bind(&cfg.s3_bucket)
    .bind(&object_key)
    .execute(pool)
    .await;
    otel::end_dep(sp);
    r?;

    let ttl = cfg.presign_upload_ttl_seconds;
    let url = s3
        .presign_put(&object_key, mime, ttl)
        .await
        .map_err(|e| MediaError::Storage(e.to_string()))?;
    metrics::MEDIA_UPLOADS.inc();
    Ok(IssueResult {
        media_id: media_id.to_string(),
        upload_url: url,
        method: "PUT",
        content_type: mime.to_string(),
        max_bytes,
        object_key,
        expires_at: Utc::now().timestamp() + ttl,
    })
}

/// POST /{id}/complete — verify owner → HeadObject confirms arrival → state=uploaded.
pub async fn complete(
    pool: &PgPool,
    s3: &S3,
    media_id: &str,
    caller_id: &str,
    sha256: &str,
    declared_bytes: i64,
) -> Result<MediaInfo, MediaError> {
    let mid = Uuid::parse_str(media_id).map_err(|_| MediaError::NotFound)?;
    let caller = Uuid::parse_str(caller_id).map_err(|_| MediaError::Forbidden)?;

    let sp = dep("SELECT media_objects for complete");
    let row = sqlx::query(
        "SELECT owner_id, object_key, state FROM media_objects WHERE id=$1 AND state <> 'deleted'",
    )
    .bind(mid)
    .fetch_optional(pool)
    .await;
    otel::end_dep(sp);
    let row = row?.ok_or(MediaError::NotFound)?;
    let owner: Uuid = row.get("owner_id");
    let object_key: String = row.get("object_key");
    let state: String = row.get("state");
    if owner != caller {
        return Err(MediaError::Forbidden);
    }
    if state != "pending" && state != "uploaded" {
        return Err(MediaError::Conflict(format!("cannot complete from state {state}")));
    }

    // HeadObject confirms the PUT actually landed (and gives us the real size).
    let real_bytes = match s3
        .head_object(&object_key)
        .await
        .map_err(|e| MediaError::Storage(e.to_string()))?
    {
        Some(b) => b,
        None => return Err(MediaError::Conflict("upload not found in object store (PUT not completed)".into())),
    };
    if declared_bytes > 0 && real_bytes > 0 && declared_bytes != real_bytes {
        return Err(MediaError::Conflict(format!(
            "declared bytes {declared_bytes} != stored bytes {real_bytes}"
        )));
    }
    let bytes = if real_bytes > 0 { real_bytes } else { declared_bytes };

    let sha = if sha256.trim().is_empty() { None } else { Some(sha256.trim().to_string()) };
    let sp = dep("UPDATE media_objects state=uploaded");
    let r = sqlx::query(
        "UPDATE media_objects SET state='uploaded', bytes=$2, sha256=$3, updated_at=now() \
         WHERE id=$1",
    )
    .bind(mid)
    .bind(bytes)
    .bind(sha)
    .execute(pool)
    .await;
    otel::end_dep(sp);
    r?;
    metrics::MEDIA_COMPLETED.inc();

    row_to_info(pool, mid).await?.ok_or(MediaError::NotFound)
}

/// GET /{id} — metadata + lifecycle state.
pub async fn get_media(pool: &PgPool, media_id: &str) -> Result<MediaInfo, MediaError> {
    let mid = Uuid::parse_str(media_id).map_err(|_| MediaError::NotFound)?;
    row_to_info(pool, mid).await?.ok_or(MediaError::NotFound)
}

pub struct SignedResult {
    pub signed_url: String,
    pub expires_at: i64,
    pub variant: String,
}

/// True if `caller` may read `media` (owner, admin, kyc_doc admin/owner-only, or an explicit grant).
async fn authorize_read(
    pool: &PgPool,
    media_id: Uuid,
    owner: Uuid,
    scope: &str,
    caller_id: &str,
    caller_role: &str,
) -> Result<bool, MediaError> {
    let is_admin = caller_role == "admin";
    if is_admin {
        return Ok(true);
    }
    let caller = match Uuid::parse_str(caller_id) {
        Ok(c) => c,
        Err(_) => return Ok(false),
    };
    if caller == owner {
        return Ok(true);
    }
    // KYC docs: owner-or-admin only, grants do not apply.
    if ADMIN_ONLY_SCOPES.contains(&scope) {
        return Ok(false);
    }
    // other scopes: owner-or-grantee.
    let sp = dep("SELECT media_grants exists");
    let r = sqlx::query("SELECT 1 FROM media_grants WHERE media_id=$1 AND grantee_id=$2")
        .bind(media_id)
        .bind(caller)
        .fetch_optional(pool)
        .await;
    otel::end_dep(sp);
    Ok(r?.is_some())
}

/// GET /{id}/signed-url?variant= — authz + presign a GET for the chosen variant.
pub async fn signed_url(
    pool: &PgPool,
    s3: &S3,
    cfg: &Config,
    media_id: &str,
    variant: &str,
    caller_id: &str,
    caller_role: &str,
) -> Result<SignedResult, MediaError> {
    let mid = Uuid::parse_str(media_id).map_err(|_| MediaError::NotFound)?;
    let variant = if variant.trim().is_empty() { "original" } else { variant.trim() };
    if !VALID_VARIANTS.contains(&variant) {
        return Err(MediaError::Validation(format!("invalid variant: {variant}")));
    }

    let sp = dep("SELECT media_objects for signed-url");
    let row = sqlx::query(
        "SELECT owner_id, scope, state, object_key FROM media_objects \
         WHERE id=$1 AND state <> 'deleted'",
    )
    .bind(mid)
    .fetch_optional(pool)
    .await;
    otel::end_dep(sp);
    let row = row?.ok_or(MediaError::NotFound)?;
    let owner: Uuid = row.get("owner_id");
    let scope: String = row.get("scope");
    let state: String = row.get("state");
    let original_key: String = row.get("object_key");

    if !authorize_read(pool, mid, owner, &scope, caller_id, caller_role).await? {
        return Err(MediaError::Forbidden);
    }
    if state != "ready" {
        return Err(MediaError::NotReady);
    }

    // pick the object key: original vs the named derivative.
    let key = if variant == "original" {
        original_key
    } else {
        let sp = dep("SELECT media_derivatives object_key");
        let r = sqlx::query("SELECT object_key FROM media_derivatives WHERE media_id=$1 AND label=$2")
            .bind(mid)
            .bind(variant)
            .fetch_optional(pool)
            .await;
        otel::end_dep(sp);
        match r? {
            Some(dr) => dr.get::<String, _>("object_key"),
            None => return Err(MediaError::NotFound),
        }
    };

    let ttl = cfg.presign_download_ttl_seconds;
    let url = s3
        .presign_get(&key, ttl)
        .await
        .map_err(|e| MediaError::Storage(e.to_string()))?;
    metrics::MEDIA_SIGNED_URLS.inc();
    Ok(SignedResult {
        signed_url: url,
        expires_at: Utc::now().timestamp() + ttl,
        variant: variant.to_string(),
    })
}

/// GET /api/v1/media — list the caller's own objects (optional scope/state filter).
pub async fn list_mine(
    pool: &PgPool,
    owner_id: &str,
    scope: Option<&str>,
    state: Option<&str>,
) -> Result<Vec<MediaInfo>, MediaError> {
    let owner = Uuid::parse_str(owner_id)
        .map_err(|_| MediaError::Validation("owner_id is not a valid uuid".into()))?;
    let sp = dep("SELECT media_objects list mine");
    let rows = sqlx::query(
        "SELECT id, owner_id, scope, kind, mime, COALESCE(bytes,0) AS bytes, state, \
         COALESCE(av_clean,false) AS av_clean, derivatives_ready, object_key \
         FROM media_objects \
         WHERE owner_id=$1 AND state <> 'deleted' \
           AND ($2::text IS NULL OR scope=$2) \
           AND ($3::text IS NULL OR state=$3) \
         ORDER BY created_at DESC LIMIT 200",
    )
    .bind(owner)
    .bind(scope)
    .bind(state)
    .fetch_all(pool)
    .await;
    otel::end_dep(sp);
    let rows = rows?;
    Ok(rows
        .into_iter()
        .map(|r| MediaInfo {
            media_id: r.get::<Uuid, _>("id").to_string(),
            owner_id: r.get::<Uuid, _>("owner_id").to_string(),
            scope: r.get::<String, _>("scope"),
            kind: r.get::<String, _>("kind"),
            mime: r.get::<String, _>("mime"),
            bytes: r.get::<i64, _>("bytes"),
            state: r.get::<String, _>("state"),
            av_clean: r.get::<bool, _>("av_clean"),
            derivatives_ready: r.get::<bool, _>("derivatives_ready"),
            object_key: r.get::<String, _>("object_key"),
        })
        .collect())
}

/// POST /{id}/grants — owner grants another user read access.
pub async fn grant(
    pool: &PgPool,
    media_id: &str,
    owner_id: &str,
    grantee_id: &str,
) -> Result<(), MediaError> {
    let mid = Uuid::parse_str(media_id).map_err(|_| MediaError::NotFound)?;
    let owner = Uuid::parse_str(owner_id).map_err(|_| MediaError::Forbidden)?;
    let grantee = Uuid::parse_str(grantee_id)
        .map_err(|_| MediaError::Validation("grantee_id is not a valid uuid".into()))?;

    let sp = dep("SELECT owner for grant");
    let row = sqlx::query("SELECT owner_id FROM media_objects WHERE id=$1 AND state <> 'deleted'")
        .bind(mid)
        .fetch_optional(pool)
        .await;
    otel::end_dep(sp);
    let row = row?.ok_or(MediaError::NotFound)?;
    let real_owner: Uuid = row.get("owner_id");
    if real_owner != owner {
        return Err(MediaError::Forbidden);
    }
    let sp = dep("INSERT media_grants");
    let r = sqlx::query(
        "INSERT INTO media_grants (media_id, grantee_id) VALUES ($1,$2) \
         ON CONFLICT (media_id, grantee_id) DO NOTHING",
    )
    .bind(mid)
    .bind(grantee)
    .execute(pool)
    .await;
    otel::end_dep(sp);
    r?;
    Ok(())
}

/// DELETE /{id} — soft-delete (state=deleted, soft_deleted_at=now) + media.deleted outbox, one tx.
pub async fn soft_delete(
    pool: &PgPool,
    cfg: &Config,
    media_id: &str,
    caller_id: &str,
    caller_role: &str,
) -> Result<(), MediaError> {
    let mid = Uuid::parse_str(media_id).map_err(|_| MediaError::NotFound)?;
    let is_admin = caller_role == "admin";

    let mut tx = pool.begin().await?;
    let sp = dep("SELECT for soft_delete FOR UPDATE");
    let row = sqlx::query(
        "SELECT owner_id, scope, object_key FROM media_objects \
         WHERE id=$1 AND state <> 'deleted' FOR UPDATE",
    )
    .bind(mid)
    .fetch_optional(&mut *tx)
    .await;
    otel::end_dep(sp);
    let row = row?.ok_or(MediaError::NotFound)?;
    let owner: Uuid = row.get("owner_id");
    let scope: String = row.get("scope");
    let object_key: String = row.get("object_key");

    if !is_admin {
        let caller = Uuid::parse_str(caller_id).map_err(|_| MediaError::Forbidden)?;
        if caller != owner {
            return Err(MediaError::Forbidden);
        }
    }

    let sp = dep("UPDATE media_objects state=deleted");
    sqlx::query(
        "UPDATE media_objects SET state='deleted', soft_deleted_at=now(), updated_at=now() WHERE id=$1",
    )
    .bind(mid)
    .execute(&mut *tx)
    .await?;
    otel::end_dep(sp);

    let payload = json!({
        "media_id": mid.to_string(),
        "owner_id": owner.to_string(),
        "scope": scope,
        "object_key": object_key,
        "deleted_at": Utc::now().to_rfc3339(),
    });
    let sp = dep("INSERT outbox media.deleted");
    sqlx::query("INSERT INTO outbox (topic, key, payload) VALUES ($1,$2,$3)")
        .bind(&cfg.kafka_topic_media_deleted)
        .bind(mid.to_string())
        .bind(sqlx::types::Json(&payload))
        .execute(&mut *tx)
        .await?;
    otel::end_dep(sp);

    tx.commit().await?;
    Ok(())
}
