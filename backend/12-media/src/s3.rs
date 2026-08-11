//! S3/RustFS object-store client (the media gateway's bucket). Built from Config with an
//! endpoint override + path-style for MinIO/RustFS. SigV4 presigning mints time-boxed
//! PUT (upload) / GET (download) URLs so bytes flow browser↔store, never through the app tier.
//! Every call is wrapped in an OTel dep_span(system="s3") so the Elastic Service-Map shows s3.
//! NEVER log a presigned URL — it is a bearer capability.
use crate::config::Config;
use crate::observability::otel;
use aws_sdk_s3::config::{BehaviorVersion, Credentials, Region};
use aws_sdk_s3::presigning::PresigningConfig;
use aws_sdk_s3::Client;
use std::time::Duration;

#[derive(Clone)]
pub struct S3 {
    pub client: Client,
    pub bucket: String,
}

impl S3 {
    /// Build the S3 client from cfg (endpoint override + static creds + path-style).
    pub async fn connect(cfg: &Config) -> anyhow::Result<Self> {
        let creds = Credentials::new(
            cfg.s3_access_key.clone(),
            cfg.s3_secret_key.clone(),
            None,
            None,
            "static",
        );
        let mut loader = aws_config::defaults(BehaviorVersion::latest())
            .region(Region::new(cfg.s3_region.clone()))
            .credentials_provider(creds);
        if !cfg.s3_endpoint.is_empty() {
            loader = loader.endpoint_url(cfg.s3_endpoint.clone());
        }
        let shared = loader.load().await;
        let s3conf = aws_sdk_s3::config::Builder::from(&shared)
            .force_path_style(cfg.s3_force_path_style)
            .build();
        let client = Client::from_conf(s3conf);
        Ok(Self { client, bucket: cfg.s3_bucket.clone() })
    }

    /// Create-if-missing the bucket; swallow already-owned/exists races.
    pub async fn ensure_bucket(&self) -> anyhow::Result<()> {
        let sp = otel::dep_span("HeadBucket", "s3", &self.bucket);
        let head = self.client.head_bucket().bucket(&self.bucket).send().await;
        otel::end_dep(sp);
        if head.is_ok() {
            return Ok(());
        }
        let sp = otel::dep_span("CreateBucket", "s3", &self.bucket);
        let r = self.client.create_bucket().bucket(&self.bucket).send().await;
        otel::end_dep(sp);
        match r {
            Ok(_) => Ok(()),
            Err(e) => {
                let m = format!("{e:?}");
                if m.contains("BucketAlreadyOwnedByYou") || m.contains("BucketAlreadyExists") {
                    Ok(())
                } else {
                    Err(anyhow::anyhow!("create_bucket failed: {m}"))
                }
            }
        }
    }

    /// /ready S3-reachability probe — ListBuckets (no guaranteed object key for HeadObject).
    pub async fn reachable(&self) -> bool {
        let sp = otel::dep_span("ListBuckets", "s3", "");
        let r = self.client.list_buckets().send().await;
        otel::end_dep(sp);
        if r.is_ok() {
            return true;
        }
        // fall back to HeadBucket (some S3 impls restrict ListBuckets by policy)
        let sp = otel::dep_span("HeadBucket", "s3", &self.bucket);
        let r = self.client.head_bucket().bucket(&self.bucket).send().await;
        otel::end_dep(sp);
        r.is_ok()
    }

    /// Stat an object — returns Some(content_length) if it exists, None if absent.
    pub async fn head_object(&self, key: &str) -> anyhow::Result<Option<i64>> {
        let sp = otel::dep_span("HeadObject", "s3", key);
        let r = self.client.head_object().bucket(&self.bucket).key(key).send().await;
        otel::end_dep(sp);
        match r {
            Ok(o) => Ok(Some(o.content_length().unwrap_or(0))),
            Err(e) => {
                // S3 HeadObject on a missing key returns a service error (NotFound / 404).
                let m = format!("{e:?}");
                if m.contains("NotFound") || m.contains("NoSuchKey") || m.contains("status: 404") || m.contains("status_code: 404") {
                    Ok(None)
                } else {
                    Err(anyhow::anyhow!("head_object failed: {m}"))
                }
            }
        }
    }

    /// Presigned PUT (upload). TTL in seconds.
    pub async fn presign_put(&self, key: &str, content_type: &str, ttl: i64) -> anyhow::Result<String> {
        let pc = PresigningConfig::expires_in(Duration::from_secs(ttl.max(1) as u64))?;
        let sp = otel::dep_span("PutObject presign", "s3", key);
        let req = self
            .client
            .put_object()
            .bucket(&self.bucket)
            .key(key)
            .content_type(content_type)
            .presigned(pc)
            .await;
        otel::end_dep(sp);
        let req = req?;
        Ok(req.uri().to_string())
    }

    /// Presigned GET (download). TTL in seconds.
    pub async fn presign_get(&self, key: &str, ttl: i64) -> anyhow::Result<String> {
        let pc = PresigningConfig::expires_in(Duration::from_secs(ttl.max(1) as u64))?;
        let sp = otel::dep_span("GetObject presign", "s3", key);
        let req = self
            .client
            .get_object()
            .bucket(&self.bucket)
            .key(key)
            .presigned(pc)
            .await;
        otel::end_dep(sp);
        let req = req?;
        Ok(req.uri().to_string())
    }
}
