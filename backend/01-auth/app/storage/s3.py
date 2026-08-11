"""RustFS / S3 client + HeadBucket health probe.

Used by /health.checks.s3_kyc. The bucket itself is created
on first boot by app.lifecycle.ensure_db's S3 bootstrap step (next to the
DB creation) — see `ensure_kyc_bucket`.
"""
from __future__ import annotations
import asyncio
import logging
from typing import Tuple

from app.config import settings

log = logging.getLogger("auth.storage.s3")


def _check_bucket_sync() -> tuple[bool, str]:
    """Sync HeadBucket against RustFS. Run via asyncio.to_thread from the
    async health-probe.
    """
    if not settings.s3_endpoint or not settings.s3_access_key:
        return False, "S3 not configured"
    try:
        import boto3
        from botocore.config import Config
        from botocore.exceptions import ClientError
        s3 = boto3.client(
            "s3",
            endpoint_url=settings.s3_endpoint,
            region_name=settings.s3_region,
            aws_access_key_id=settings.s3_access_key,
            aws_secret_access_key=settings.s3_secret_key,
            config=Config(
                signature_version="s3v4",
                connect_timeout=2,
                read_timeout=2,
                retries={"max_attempts": 1},
                s3={"addressing_style": "path" if settings.s3_force_path_style else "auto"},
            ),
        )
        try:
            s3.head_bucket(Bucket=settings.s3_bucket)
            return True, "HeadBucket 200"
        except ClientError as e:
            code = e.response.get("Error", {}).get("Code", "?")
            status = e.response.get("ResponseMetadata", {}).get("HTTPStatusCode", "?")
            return False, f"HeadBucket {status} {code}"
    except Exception as e:
        return False, f"{type(e).__name__}: {str(e)[:60]}"


async def check_s3() -> tuple[bool, str]:
    return await asyncio.to_thread(_check_bucket_sync)


def ensure_bucket() -> None:
    """Create the KYC bucket if missing. Sync, called from lifecycle.ensure_db."""
    if not settings.s3_endpoint:
        log.warning("S3 not configured — skipping ensure_bucket")
        return
    import boto3
    from botocore.config import Config
    from botocore.exceptions import ClientError
    s3 = boto3.client(
        "s3",
        endpoint_url=settings.s3_endpoint,
        region_name=settings.s3_region,
        aws_access_key_id=settings.s3_access_key,
        aws_secret_access_key=settings.s3_secret_key,
        config=Config(
            signature_version="s3v4", connect_timeout=3, read_timeout=3,
            s3={"addressing_style": "path" if settings.s3_force_path_style else "auto"},
        ),
    )
    try:
        s3.head_bucket(Bucket=settings.s3_bucket)
        log.info("kyc bucket exists: %s", settings.s3_bucket)
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") in ("404", "NoSuchBucket", "NotFound"):
            s3.create_bucket(Bucket=settings.s3_bucket)
            log.info("created kyc bucket: %s", settings.s3_bucket)
        else:
            raise
