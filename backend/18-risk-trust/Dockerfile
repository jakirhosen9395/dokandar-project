# syntax=docker/dockerfile:1
FROM python:3.13-slim AS base
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app

FROM base AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential libpq-dev \
 && rm -rf /var/lib/apt/lists/*
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY pyproject.toml ./
RUN pip install --upgrade pip setuptools wheel && pip install .

FROM base AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends libpq5 curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 10001 --create-home appuser
COPY --from=build /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY app ./app
COPY migrations ./migrations
COPY proto ./proto
COPY CODE_VERSION ./CODE_VERSION
USER appuser
EXPOSE 8000 50051
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
    CMD curl -fsS "http://localhost:${SERVICE_PORT:-8000}/ready" >/dev/null || exit 1
ENTRYPOINT ["sh","-c","python -m app.lifecycle.ensure_db && exec uvicorn app.main:app --host 0.0.0.0 --port ${SERVICE_PORT:-8000}"]
