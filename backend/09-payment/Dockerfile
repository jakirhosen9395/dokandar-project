# syntax=docker/dockerfile:1
# DOKANDAR 09-payment — Elixir 1.20 / Phoenix 1.8 (Postgres + Redis DB8 + RabbitMQ; REST 4000).
FROM elixir:1.20-otp-27 AS build
WORKDIR /app
ENV MIX_ENV=prod MIX_HOME=/opt/mix
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates build-essential cmake git \
 && rm -rf /var/lib/apt/lists/* \
 && mix local.hex --force && mix local.rebar --force
COPY mix.exs ./
RUN mix deps.get --only prod
COPY config ./config
RUN mix deps.compile
COPY lib ./lib
COPY CODE_VERSION ./CODE_VERSION
COPY migrations ./migrations
RUN mix compile

FROM elixir:1.20-otp-27-slim AS runtime
WORKDIR /app
ENV MIX_ENV=prod MIX_HOME=/opt/mix
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 10001 --create-home appuser
COPY --from=build --chown=10001:10001 /opt/mix /opt/mix
COPY --from=build --chown=10001:10001 /app /app
USER appuser
EXPOSE 4000
HEALTHCHECK --interval=30s --timeout=3s --start-period=50s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${SERVICE_PORT:-4000}/ready" || exit 1
ENTRYPOINT ["sh","-c","exec mix phx.server"]
