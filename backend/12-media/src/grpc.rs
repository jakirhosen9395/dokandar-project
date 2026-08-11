//! East-west gRPC surface (tonic 0.13). Every RPC requires x-internal-token == INTERNAL_SERVICE_TOKEN
//! compared constant-time (subtle), fail-closed on empty → UNAUTHENTICATED (code 16). The handlers
//! delegate to the same domain fns the REST surface uses; MediaError maps to tonic::Status.
//!
//! NOTE: prost folds the proto `URL` acronym to `Url` — so the generated messages are
//! IssueUploadUrlRequest / UploadUrlResponse / GetSignedUrlRequest / SignedUrlResponse, and the
//! methods are issue_upload_url / mark_uploaded / get_signed_url / get_media.
use crate::config::Config;
use crate::domain::{self, MediaError};
use crate::pb;
use crate::s3::S3;
use sqlx::postgres::PgPool;
use tonic::{transport::Server, Request, Response, Status};

use pb::media_server::{Media, MediaServer};

/// Constant-time x-internal-token check; fail-closed on empty config.
fn check_token(cfg: &Config, md: &tonic::metadata::MetadataMap) -> Result<(), Status> {
    let presented = md
        .get("x-internal-token")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    if crate::auth::internal_token_ok(presented, cfg) {
        Ok(())
    } else {
        Err(Status::unauthenticated("invalid or missing x-internal-token"))
    }
}

fn map_err(e: MediaError) -> Status {
    let (_, code) = e.parts();
    let msg = format!("{}: {}", code, e.message());
    match e {
        MediaError::NotFound => Status::not_found(msg),
        MediaError::Forbidden => Status::permission_denied(msg),
        MediaError::NotReady | MediaError::Conflict(_) => Status::failed_precondition(msg),
        MediaError::Validation(_) => Status::invalid_argument(msg),
        MediaError::Storage(_) => Status::unavailable(msg),
        MediaError::Db(_) => Status::internal("internal error"),
    }
}

fn to_info(i: domain::MediaInfo) -> pb::MediaInfo {
    pb::MediaInfo {
        media_id: i.media_id,
        owner_id: i.owner_id,
        scope: i.scope,
        mime: i.mime,
        bytes: i.bytes,
        state: i.state,
        av_clean: i.av_clean,
        derivatives_ready: i.derivatives_ready,
        object_key: i.object_key,
    }
}

pub struct MediaSvc {
    pub cfg: Config,
    pub pool: PgPool,
    pub s3: S3,
}

#[tonic::async_trait]
impl Media for MediaSvc {
    async fn issue_upload_url(
        &self,
        req: Request<pb::IssueUploadUrlRequest>,
    ) -> Result<Response<pb::UploadUrlResponse>, Status> {
        check_token(&self.cfg, req.metadata())?;
        let r = req.into_inner();
        let res = domain::issue_upload(
            &self.pool,
            &self.s3,
            &self.cfg,
            &r.owner_id,
            &r.scope,
            "generic",
            &r.mime,
            r.max_bytes,
        )
        .await
        .map_err(map_err)?;
        Ok(Response::new(pb::UploadUrlResponse {
            media_id: res.media_id,
            upload_url: res.upload_url,
            method: res.method.to_string(),
            content_type: res.content_type,
            max_bytes: res.max_bytes,
            expires_at: res.expires_at,
        }))
    }

    async fn mark_uploaded(
        &self,
        req: Request<pb::MarkUploadedRequest>,
    ) -> Result<Response<pb::MediaInfo>, Status> {
        check_token(&self.cfg, req.metadata())?;
        let r = req.into_inner();
        // east-west caller is trusted; fetch the owner to satisfy the owner check.
        let owner = domain::get_media(&self.pool, &r.media_id)
            .await
            .map_err(map_err)?
            .owner_id;
        let info = domain::complete(&self.pool, &self.s3, &r.media_id, &owner, &r.sha256, r.bytes)
            .await
            .map_err(map_err)?;
        Ok(Response::new(to_info(info)))
    }

    async fn get_signed_url(
        &self,
        req: Request<pb::GetSignedUrlRequest>,
    ) -> Result<Response<pb::SignedUrlResponse>, Status> {
        check_token(&self.cfg, req.metadata())?;
        let r = req.into_inner();
        // east-west: caller_user_id is the authorization subject; role unknown → "" (non-admin).
        let res = domain::signed_url(
            &self.pool,
            &self.s3,
            &self.cfg,
            &r.media_id,
            &r.variant,
            &r.caller_user_id,
            "",
        )
        .await
        .map_err(map_err)?;
        Ok(Response::new(pb::SignedUrlResponse {
            signed_url: res.signed_url,
            expires_at: res.expires_at,
        }))
    }

    async fn get_media(
        &self,
        req: Request<pb::GetMediaRequest>,
    ) -> Result<Response<pb::MediaInfo>, Status> {
        check_token(&self.cfg, req.metadata())?;
        let r = req.into_inner();
        let info = domain::get_media(&self.pool, &r.media_id).await.map_err(map_err)?;
        Ok(Response::new(to_info(info)))
    }
}

/// Spawn the tonic server on 0.0.0.0:grpc_port.
pub async fn serve(cfg: Config, pool: PgPool, s3: S3) {
    let addr = match format!("0.0.0.0:{}", cfg.grpc_port).parse() {
        Ok(a) => a,
        Err(e) => {
            crate::observability::logging::error("media.grpc", &format!("bad grpc addr: {e}"));
            return;
        }
    };
    let svc = MediaSvc { cfg: cfg.clone(), pool, s3 };
    crate::observability::logging::warn("media.grpc", &format!("gRPC listening on :{}", cfg.grpc_port));
    let server = Server::builder().add_service(MediaServer::new(svc)).serve(addr);
    if let Err(e) = server.await {
        crate::observability::logging::error("media.grpc", &format!("gRPC serve failed: {e}"));
    }
}
