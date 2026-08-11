# syntax=docker/dockerfile:1
# DOKANDAR 17-shipping — Ruby 3.4 / Rails 8.1 (PostgreSQL + Neo4j + Kafka + gRPC).
ARG RUBY_VERSION=3.4.9
FROM ruby:${RUBY_VERSION}-slim AS build
WORKDIR /app
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      build-essential git libpq-dev libyaml-dev pkg-config zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*
ENV BUNDLE_PATH=/usr/local/bundle BUNDLE_DEPLOYMENT=1
# gems first (cached unless Gemfile/lock change), then app code.
COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4 && rm -rf "${BUNDLE_PATH}"/cache "${BUNDLE_PATH}"/ruby/*/cache
COPY . .

FROM ruby:${RUBY_VERSION}-slim AS runtime
WORKDIR /app
# runtime libs: pg (libpq5), puma/openssl (libssl3), + librdkafka deps (libsasl2/zstd/lz4)
# so the Kafka layer needs no base rebuild. curl for the healthcheck; postgresql-client for ensure-db.
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      curl ca-certificates tzdata libpq5 libssl3 zlib1g libsasl2-2 libzstd1 liblz4-1 postgresql-client \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -u 10001 -m app
ENV RAILS_ENV=production BUNDLE_PATH=/usr/local/bundle BUNDLE_DEPLOYMENT=1 \
    PATH=/usr/local/bundle/bin:$PATH
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app
RUN chown -R 10001:10001 /app
USER 10001
# internal binds: REST on ${SERVICE_PORT} (env file renders 8000; puma.rb falls back to 3000
# when unset), gRPC on ${GRPC_PORT:-8001}. No ports are baked — config arrives via --env-file.
EXPOSE 8000 8001
HEALTHCHECK --interval=30s --timeout=3s --start-period=50s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${SERVICE_PORT:-3000}/ready" >/dev/null || exit 1
# ensure-db (db:prepare = create-if-missing + migrate, §16-i), then Puma (which boots the
# gRPC server + Kafka consumer + outbox relay as threads).
ENTRYPOINT ["bash","-lc","bundle exec rails db:prepare 2>&1 | tail -4; bundle exec rails db:seed 2>&1 | tail -3; exec bundle exec puma -C config/puma.rb"]
