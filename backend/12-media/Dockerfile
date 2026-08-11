# syntax=docker/dockerfile:1
# DOKANDAR 12-media — Rust / Actix Web 4 + tonic gRPC + S3 (RustFS/MinIO).
# Two-stage: build with the full toolchain (protoc for tonic-build, cmake for rdkafka), ship slim.
FROM rust:1-bookworm AS build
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
      protobuf-compiler cmake build-essential pkg-config libssl-dev \
      zlib1g-dev libsasl2-dev libzstd-dev \
    && rm -rf /var/lib/apt/lists/*
# dep cache: build deps (lockfile-pinned) against a dummy main before copying real src.
COPY Cargo.toml Cargo.lock build.rs ./
COPY proto ./proto
RUN mkdir src && echo "fn main(){}" > src/main.rs \
    && cargo build --release --locked \
    && rm -rf src
COPY src ./src
RUN touch src/main.rs && cargo build --release --locked

FROM debian:bookworm-slim AS runtime
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates libssl3 zlib1g libsasl2-2 libzstd1 curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin appuser
COPY --from=build /app/target/release/dokandar-media /app/dokandar-media
COPY migrations ./migrations
COPY CODE_VERSION ./CODE_VERSION
COPY data ./data
USER appuser
EXPOSE 8080 50051
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${SERVICE_PORT:-8080}/ready" || exit 1
ENTRYPOINT ["/app/dokandar-media"]
