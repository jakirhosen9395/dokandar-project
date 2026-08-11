"""Env-var configuration. FR-ANL-012's 1.15 safety factor is CANON; window sizes are policy."""

from __future__ import annotations

import os
from dataclasses import dataclass

SHORTAGE_SAFETY_FACTOR = 1.15  # FR-ANL-012 default safety factor — canon value


@dataclass(frozen=True)
class Config:
    port: int
    ch_url: str
    ch_user: str
    ch_password: str
    kafka_brokers: str
    demand_window_ms: int
    build_info_path: str


def load() -> Config:
    return Config(
        port=int(os.environ.get("DKD_PORT", "8080")),
        ch_url=os.environ.get("DKD_CH_URL", "http://localhost:8123"),
        ch_user=os.environ.get("DKD_CH_USER", "default"),
        ch_password=os.environ.get("DKD_CH_PASSWORD", ""),
        kafka_brokers=os.environ.get("DKD_KAFKA_BROKERS", "localhost:9092"),
        demand_window_ms=int(os.environ.get("DKD_DEMAND_WINDOW_MS", "604800000")),  # 7d
        build_info_path=os.environ.get("DKD_BUILD_INFO_PATH", "/app/build-info.json"),
    )
