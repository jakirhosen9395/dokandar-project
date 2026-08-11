from __future__ import annotations
import os
from pathlib import Path
from pydantic_settings import BaseSettings, SettingsConfigDict

APP_ENV = os.environ.get("APP_ENV", "dev")
_ROOT = Path(__file__).resolve().parents[1]
_ENV_FILE = _ROOT / "env" / f".env.{APP_ENV}"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=str(_ENV_FILE) if _ENV_FILE.exists() else None,
        env_file_encoding="utf-8", case_sensitive=False, extra="ignore",
    )
    app_env: str = APP_ENV
    service_name: str = "16-recommendation"
    env_version: str = "v1.0.0"
    tenant: str = "local"
    service_port: int = 10016
    grpc_enabled: bool = True
    grpc_port: int = 50051
    log_level: str = "info"

    postgres_host: str
    postgres_port: int = 5432
    postgres_user: str
    postgres_password: str
    postgres_db: str = "dokandar_recommendation_dev"

    qdrant_url: str = ""
    qdrant_api_key: str = ""
    qdrant_collection_user: str = "dokandar_user_embeddings"
    qdrant_collection_product: str = "dokandar_product_embeddings"
    qdrant_collection_shop: str = "dokandar_shop_embeddings"

    redis_host: str = ""
    redis_port: int = 6379
    redis_password: str = ""
    redis_db: int = 14
    feed_cache_ttl_seconds: int = 600

    kafka_bootstrap: str = ""
    kafka_group_prefix: str = "reco"
    kafka_topic_product: str = "dokandar.product.changed"
    kafka_topic_order: str = "dokandar.order.placed"
    kafka_topic_review: str = "dokandar.review.posted"

    mongo_log_uri: str = ""
    mongo_log_db: str = "mongo_db_dokandar_application_logs"
    elastic_search_url: str = ""
    elastic_search_username: str = ""
    elastic_search_password: str = ""

    apm_server_url: str = ""
    apm_secret_token: str = ""
    apm_service_name: str = "16-recommendation"

    jwt_public_key_b64: str = ""
    jwt_issuer: str = "dokandar-auth"
    internal_service_token: str = ""

    feed_default_size: int = 30

    @property
    def postgres_dsn(self) -> str:
        return f"postgresql://{self.postgres_user}:{self.postgres_password}@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"

    @property
    def postgres_admin_dsn(self) -> str:
        return f"postgresql://{self.postgres_user}:{self.postgres_password}@{self.postgres_host}:{self.postgres_port}/postgres"

    @property
    def code_version(self) -> str:
        cv = _ROOT / "CODE_VERSION"
        return cv.read_text().strip() if cv.exists() else "0-unknown"


settings = Settings()
if not settings.service_name:
    raise RuntimeError("SERVICE_NAME is empty")
if settings.app_env in {"stage", "prod"} and not settings.jwt_public_key_b64:
    raise RuntimeError("JWT_PUBLIC_KEY_B64 empty in stage/prod")
