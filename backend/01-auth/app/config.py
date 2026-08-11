"""Pydantic-settings — loads env/.env.<APP_ENV> idiomatically."""
from __future__ import annotations
import os
from pathlib import Path
from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


APP_ENV = os.environ.get("APP_ENV", "dev")
_ROOT = Path(__file__).resolve().parents[1]
_ENV_FILE = _ROOT / "env" / f".env.{APP_ENV}"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=str(_ENV_FILE) if _ENV_FILE.exists() else None,
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # identity
    app_env: str = APP_ENV
    service_name: str = "auth"
    env_version: str = "v1.0.0"
    tenant: str = "local"
    service_port: int = 8000

    # postgres
    postgres_dsn: str
    postgres_admin_dsn: str

    # redis
    redis_url: str

    # kafka
    kafka_bootstrap: str
    kafka_topic_user: str = "dokandar.user.created"
    kafka_topic_user_updated: str = "dokandar.user.updated"
    kafka_topic_kyc_submitted: str = "dokandar.kyc.submitted"
    kafka_topic_kyc_approved: str = "dokandar.kyc.approved"
    kafka_topic_kyc_rejected: str = "dokandar.kyc.rejected"

    # gRPC server runs alongside FastAPI
    grpc_port: int = 8001
    grpc_enabled: bool = True

    # rabbitmq
    rabbitmq_url: str
    rabbitmq_otp_queue: str = "notifications.otp.send"

    # mongo (logs)
    mongo_log_uri: str
    mongo_log_db: str = "dokandar_logs"

    # apm
    apm_server_url: str
    apm_secret_token: str = ""
    apm_service_name: str = "auth"

    # elasticsearch — the auth service ships application logs directly into
    # the platform's ES from inside this process (httpx → _bulk POST) so
    # Kibana → Discover / Logs lights up without any host-side shipper.
    # The in-process path stamps `service.name`/`trace.id` on every line
    # BEFORE shipping, so log → trace joins on `trace.id` always work.
    elastic_search_url: str = ""
    elastic_search_username: str = ""
    elastic_search_password: str = ""

    # S3 (RustFS in dev) — KYC document storage; /health.s3_kyc probes it
    s3_endpoint: str = ""
    s3_access_key: str = ""
    s3_secret_key: str = ""
    s3_bucket: str = "dokandar-kyc-dev"
    s3_region: str = "us-east-1"
    s3_force_path_style: bool = True

    # jwt
    jwt_private_key_b64: str = ""
    jwt_public_key_b64: str = ""
    jwt_issuer: str = "dokandar-auth"
    jwt_access_ttl_seconds: int = 900
    jwt_refresh_ttl_seconds: int = 2592000

    # otp + admin seed
    otp_enabled: bool = True
    otp_ttl_seconds: int = 300
    otp_max_attempts: int = 5
    otp_rate_per_hour: int = 5

    default_admin_phone: str = "01700000000"
    default_admin_name: str = "Platform Admin"
    internal_service_token: str = ""

    log_level: str = "info"

    @property
    def code_version(self) -> str:
        cv = (_ROOT / "CODE_VERSION")
        return cv.read_text().strip() if cv.exists() else "0-unknown"


settings = Settings()  # singleton; raises early if required envs missing
