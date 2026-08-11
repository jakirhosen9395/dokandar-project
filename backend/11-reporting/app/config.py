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
    service_name: str = "11-reporting"
    env_version: str = "v1.0.0"
    tenant: str = "local"
    service_port: int = 10011
    log_level: str = "info"

    postgres_host: str
    postgres_port: int = 5432
    postgres_user: str
    postgres_password: str
    postgres_db: str = "dokandar_reporting_dev"

    clickhouse_url: str = ""  # optional; falls back to PG facts
    redis_host: str = ""
    redis_port: int = 6379
    redis_password: str = ""
    redis_db: int = 11

    kafka_bootstrap: str = ""
    kafka_group_prefix: str = "reporting"
    kafka_topic_order_placed: str = "dokandar.order.placed"
    kafka_topic_order_status: str = "dokandar.order.status_changed"
    kafka_topic_payment_settled: str = "dokandar.payment.settled"
    kafka_topic_payout_completed: str = "dokandar.payment.payout_completed"

    mongo_log_uri: str = ""
    mongo_log_db: str = "mongo_db_dokandar_application_logs"
    elastic_search_url: str = ""
    elastic_search_username: str = ""
    elastic_search_password: str = ""

    apm_server_url: str = ""
    apm_secret_token: str = ""
    apm_service_name: str = "11-reporting"

    jwt_public_key_b64: str = ""
    jwt_issuer: str = "dokandar-auth"
    internal_service_token: str = ""

    kpi_max_range_days: int = 400

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
