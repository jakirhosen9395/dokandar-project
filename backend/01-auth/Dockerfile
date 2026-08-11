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
RUN pip install --upgrade pip wheel && pip install .

FROM base AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends libpq5 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 10001 --create-home appuser
COPY --from=build /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY app ./app
COPY proto ./proto
COPY alembic.ini ./
COPY migrations ./migrations
COPY CODE_VERSION ./CODE_VERSION
USER appuser
EXPOSE 8000 8001
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:'+str(__import__('os').environ.get('SERVICE_PORT','8000'))+'/ready',timeout=2).status==200 else 1)" || exit 1
CMD ["sh","-c","python -m app.lifecycle.ensure_db && uvicorn app.main:app --host 0.0.0.0 --port ${SERVICE_PORT:-8000}"]
