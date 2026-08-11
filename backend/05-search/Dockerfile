# syntax=docker/dockerfile:1
# DOKANDAR 05-search — Rust / Axum (CQRS read projection: PG *_view + ES :9201).
# Multi-stage: cargo build (deps cached) → slim runtime with the static-ish binary.
FROM rust:1-slim-bookworm AS build
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends pkg-config libssl-dev build-essential cmake zlib1g-dev libsasl2-dev libzstd-dev libcurl4-openssl-dev && rm -rf /var/lib/apt/lists/*
# dep cache: build a dummy main against the real Cargo.toml so the dependency
# layer caches across source edits (the hours-saver for Rust iteration).
COPY Cargo.toml ./
RUN mkdir src && echo "fn main(){}" > src/main.rs && cargo build --release && rm -rf src
COPY src ./src
RUN touch src/main.rs && cargo build --release

FROM debian:bookworm-slim AS runtime
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libssl3 zlib1g libsasl2-2 libzstd1 libcurl4 curl \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin appuser
COPY --from=build /app/target/release/dokandar-search /app/dokandar-search
COPY migrations ./migrations
COPY CODE_VERSION ./CODE_VERSION
USER appuser
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${SERVICE_PORT:-8080}/ready" || exit 1
ENTRYPOINT ["/app/dokandar-search"]
