# syntax=docker/dockerfile:1
# analytics-svc — Context #12 (Analytics & Forecasting; read-only OLAP consumer, ADR-010).
ARG GIT_SHA=unknown
ARG VERSION=0.0.0-dev
ARG BUILD_TIME=unknown

FROM python:3.12-slim AS build
WORKDIR /src
COPY pyproject.toml .
COPY src ./src
RUN pip install --no-cache-dir --prefix=/install .

FROM python:3.12-slim
ARG GIT_SHA
ARG VERSION
ARG BUILD_TIME
LABEL org.opencontainers.image.title="analytics-svc" \
      org.opencontainers.image.description="DOKANDAR Context #12 Analytics — ClickHouse facts + advisory views (never produces events)" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${BUILD_TIME}" \
      org.opencontainers.image.source="https://gitlab.com/final-year-project3354127/dkd-analytics"
COPY --from=build /install /usr/local
RUN mkdir -p /app && printf '{"version":"%s","gitSha":"%s","buildTime":"%s"}' "$VERSION" "$GIT_SHA" "$BUILD_TIME" > /app/build-info.json
EXPOSE 8080
CMD ["python","-m","analytics.main"]
