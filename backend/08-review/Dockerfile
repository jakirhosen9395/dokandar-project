# syntax=docker/dockerfile:1
# DOKANDAR 08-review — Kotlin 2.4 / Ktor 3.5 (PostgreSQL + Elasticsearch + Kafka + gRPC).
FROM gradle:8.11-jdk21 AS build
WORKDIR /src
COPY settings.gradle.kts build.gradle.kts ./
COPY src ./src
RUN --mount=type=cache,target=/root/.gradle gradle --no-daemon -g /root/.gradle shadowJar

FROM eclipse-temurin:21-jre
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* && useradd --uid 10001 --create-home appuser
# Elastic APM Java agent — bootstrap-loaded (Family B); reads ELASTIC_APM_* from env.
ARG ELASTIC_APM_VERSION=1.55.6
RUN curl -fsSL -o /elastic-apm-agent.jar \
    https://repo1.maven.org/maven2/co/elastic/apm/elastic-apm-agent/${ELASTIC_APM_VERSION}/elastic-apm-agent-${ELASTIC_APM_VERSION}.jar \
 && test -f /elastic-apm-agent.jar
COPY --from=build /src/build/libs/review.jar /app/review.jar
COPY CODE_VERSION /app/CODE_VERSION
COPY migrations /app/migrations
COPY data /app/data
USER 10001
EXPOSE 8080 50051
HEALTHCHECK --interval=30s --timeout=3s --start-period=70s --retries=3 \
  CMD curl -fsS "http://localhost:${SERVICE_PORT:-8080}/ready" || exit 1
# Map the rendered APM_* env → the ELASTIC_APM_* the Java agent reads; enable MDC log correlation
# (so trace.id/transaction.id reach the logger) and wire service.version from CODE_VERSION.
ENTRYPOINT ["sh","-c","export ELASTIC_APM_SERVER_URL=\"$APM_SERVER_URL\" ELASTIC_APM_SECRET_TOKEN=\"$APM_SECRET_TOKEN\" ELASTIC_APM_SERVICE_NAME=\"${APM_SERVICE_NAME:-$SERVICE_NAME}\" ELASTIC_APM_ENVIRONMENT=\"$APP_ENV\" ELASTIC_APM_SERVICE_VERSION=\"$(cat /app/CODE_VERSION)\" ELASTIC_APM_APPLICATION_PACKAGES=com.dokandar.review ELASTIC_APM_VERIFY_SERVER_CERT=false ELASTIC_APM_ENABLE_LOG_CORRELATION=true ELASTIC_APM_TRANSACTION_IGNORE_URLS=/metrics,/health,/openapi.json,/docs; exec java -javaagent:/elastic-apm-agent.jar -jar /app/review.jar"]
