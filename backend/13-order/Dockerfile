# syntax=docker/dockerfile:1
# ── Build stage: Maven + JDK 25 → fat jar (protoc/gRPC codegen runs in-build) ──
FROM maven:3.9-eclipse-temurin-25 AS build
WORKDIR /src
COPY pom.xml ./
RUN mvn -B -ntp -q dependency:go-offline || true
COPY proto ./proto
COPY src ./src
COPY CODE_VERSION ./CODE_VERSION
RUN mvn -B -ntp -DskipTests clean package

# ── Runtime stage: JRE 25, non-root uid 10001, Elastic APM -javaagent ──
FROM eclipse-temurin:25-jre
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 10001 --create-home appuser

# Elastic APM Java agent — attached via -javaagent so JDBC/Kafka/Servlet/gRPC is
# auto-instrumented (APM Family B: bootstrap-loaded, outermost by construction).
ARG ELASTIC_APM_VERSION=1.55.6
RUN curl -fsSL -o /elastic-apm-agent.jar \
    https://repo1.maven.org/maven2/co/elastic/apm/elastic-apm-agent/${ELASTIC_APM_VERSION}/elastic-apm-agent-${ELASTIC_APM_VERSION}.jar

COPY --from=build /src/target/order.jar /app/order.jar
COPY CODE_VERSION /app/CODE_VERSION

USER 10001
# in-container REST 8080 / gRPC 9090 (LB maps external 10013 / 20013)
EXPOSE 8080 9090

HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
  CMD curl -fsS http://localhost:${SERVICE_PORT:-8080}/ready || exit 1

# The agent reads ELASTIC_APM_* from the env (rendered into .env.dev). We map the
# app-probe APM_* -> ELASTIC_APM_* (so a deploy supplying only APM_* still attaches),
# set SERVICE_NAME/VERSION from identity, and IGNORE the six handled-4xx exceptions
# so they don't surface as APM errors. ENABLE_LOG_CORRELATION injects trace.id into MDC.
ENTRYPOINT ["sh","-c","\
  export ELASTIC_APM_SERVER_URL=\"${ELASTIC_APM_SERVER_URL:-$APM_SERVER_URL}\" ; \
  export ELASTIC_APM_SECRET_TOKEN=\"${ELASTIC_APM_SECRET_TOKEN:-$APM_SECRET_TOKEN}\" ; \
  export ELASTIC_APM_SERVICE_NAME=\"${ELASTIC_APM_SERVICE_NAME:-${SERVICE_NAME:-13-order}}\" ; \
  export ELASTIC_APM_SERVICE_VERSION=\"${ELASTIC_APM_SERVICE_VERSION:-$(cat /app/CODE_VERSION 2>/dev/null || echo 13-order)}\" ; \
  export ELASTIC_APM_ENVIRONMENT=\"${ELASTIC_APM_ENVIRONMENT:-${APP_ENV:-dev}}\" ; \
  export ELASTIC_APM_ENABLE_LOG_CORRELATION=true ; \
  export ELASTIC_APM_IGNORE_EXCEPTIONS=\"${ELASTIC_APM_IGNORE_EXCEPTIONS:-com.dokandar.order.api.ApiException,com.dokandar.order.auth.JwtAuth\\$UnauthorizedException,org.springframework.web.servlet.NoHandlerFoundException,org.springframework.web.servlet.resource.NoResourceFoundException,org.springframework.web.HttpRequestMethodNotSupportedException,org.springframework.http.converter.HttpMessageNotReadableException,com.dokandar.order.grpc.clients.CatalogClient\\$CatalogStockException,com.dokandar.order.grpc.clients.WalletClient\\$WalletException,com.dokandar.order.grpc.clients.PaymentClient\\$PaymentException}\" ; \
  exec java -javaagent:/elastic-apm-agent.jar -jar /app/order.jar"]
