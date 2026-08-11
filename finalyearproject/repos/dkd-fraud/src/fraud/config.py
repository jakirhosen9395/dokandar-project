"""Env-var configuration. Thresholds are POLICY DATA (FR-GOV-013/FR-SCM-018: config-driven,
versioned) — canon defines the FR-SCM-020 bands but no velocity values; dev defaults here."""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    port: int
    metrics_port: int
    db_dsn: str
    redis_url: str
    kafka_brokers: str
    rabbit_url: str
    velocity_window_ms: int
    velocity_threshold: int
    profile_ttl_s: int
    model_version: str
    build_info_path: str


def load() -> Config:
    return Config(
        port=int(os.environ.get("DKD_PORT", "8080")),
        metrics_port=int(os.environ.get("DKD_METRICS_PORT", "9090")),
        db_dsn=os.environ.get("DKD_DB_DSN", "postgresql://dokandar@localhost:5432/dkd_fraud"),
        redis_url=os.environ.get("DKD_REDIS_URL", "redis://localhost:6379/3"),
        kafka_brokers=os.environ.get("DKD_KAFKA_BROKERS", "localhost:9092"),
        rabbit_url=os.environ.get("DKD_RABBIT_URL", "amqp://guest:guest@localhost:5672/%2F"),
        velocity_window_ms=int(os.environ.get("DKD_FRAUD_VELOCITY_WINDOW_MS", "86400000")),
        velocity_threshold=int(os.environ.get("DKD_FRAUD_VELOCITY_THRESHOLD", "10")),
        profile_ttl_s=int(os.environ.get("DKD_FRAUD_PROFILE_TTL_S", "86400")),
        model_version=os.environ.get("DKD_FRAUD_MODEL_VERSION", "rule-v1"),
        build_info_path=os.environ.get("DKD_BUILD_INFO_PATH", "/app/build-info.json"),
    )


def validate(cfg: Config) -> None:
    if not cfg.db_dsn:
        raise ValueError("DKD_DB_DSN is required")
    if cfg.velocity_threshold <= 0:
        raise ValueError("DKD_FRAUD_VELOCITY_THRESHOLD must be > 0")
