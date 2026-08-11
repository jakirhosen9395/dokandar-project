# syntax=docker/dockerfile:1
FROM python:3.12-slim AS base
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app

FROM base AS build
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt ./
RUN pip install --upgrade pip wheel && pip install -r requirements.txt

FROM base AS runtime
RUN useradd --uid 10001 --create-home appuser
COPY --from=build /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY app.py ./
COPY CODE_VERSION ./CODE_VERSION
USER appuser
EXPOSE 8000
# Probe /ready (LB gate, 200 when the process is up) — not /health, which flips to
# 503 on best-effort RabbitMQ hiccups and would flap the container to unhealthy.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:'+str(__import__('os').environ.get('SERVICE_PORT','8000'))+'/ready',timeout=2).status==200 else 1)" || exit 1
CMD ["sh","-c","uvicorn app:app --host 0.0.0.0 --port ${SERVICE_PORT:-8000}"]
