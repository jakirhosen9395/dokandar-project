# syntax=docker/dockerfile:1
# fraud-svc — Context #10 (Fraud, Risk & Enforcement, R4 recommend-by-default).
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
LABEL org.opencontainers.image.title="fraud-svc" \
      org.opencontainers.image.description="DOKANDAR Context #10 Fraud — advisory scoring + four-eyes holds (R4)" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${BUILD_TIME}" \
      org.opencontainers.image.source="https://gitlab.com/final-year-project3354127/dkd-fraud"
COPY --from=build /install /usr/local
RUN printf '{"version":"%s","gitSha":"%s","buildTime":"%s"}' "$VERSION" "$GIT_SHA" "$BUILD_TIME" > /app-build-info.json \
    && mkdir -p /app && mv /app-build-info.json /app/build-info.json
EXPOSE 8080 9090
CMD ["python","-m","fraud.main"]
