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

# ── Runtime stage: distroless-ish JRE 25, non-root uid 10001, APM -javaagent ──
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

COPY --from=build /src/target/catalog.jar /app/catalog.jar
COPY CODE_VERSION /app/CODE_VERSION

USER 10001
# in-container REST 8080 / gRPC 9090 (LB maps external 10004 / 20004)
EXPOSE 8080 9090

HEALTHCHECK --interval=30s --timeout=3s --start-period=45s --retries=3 \
  CMD curl -fsS http://localhost:${SERVICE_PORT:-8080}/ready || exit 1

# The agent reads ELASTIC_APM_* from the env (rendered into .env.dev). SERVICE_VERSION=CODE_VERSION (§16-e).
ENTRYPOINT ["sh","-c","exec java -javaagent:/elastic-apm-agent.jar -jar /app/catalog.jar"]
