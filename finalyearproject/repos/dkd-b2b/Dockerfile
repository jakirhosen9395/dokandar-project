# syntax=docker/dockerfile:1
# b2b-trade-svc — Context #7 (B2B Trade & Commodity Exchange). Single-source provenance:
# GIT_SHA/VERSION/BUILD_TIME arrive once as build-args -> build-info.properties + OCI labels.
ARG GIT_SHA=unknown
ARG VERSION=0.0.0-dev
ARG BUILD_TIME=unknown

FROM maven:3.9-eclipse-temurin-21 AS build
ARG GIT_SHA
ARG VERSION
ARG BUILD_TIME
WORKDIR /src
COPY . .
RUN mvn -q -B -DskipTests package
RUN printf 'version=%s\ngitSha=%s\nbuildTime=%s\n' "$VERSION" "$GIT_SHA" "$BUILD_TIME" > /src/build-info.properties

FROM eclipse-temurin:21-jre
ARG GIT_SHA
ARG VERSION
ARG BUILD_TIME
LABEL org.opencontainers.image.title="b2b-trade-svc" \
      org.opencontainers.image.description="DOKANDAR Context #7 B2B Trade — TradeOrder margining + Saga 4 settlement" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${BUILD_TIME}" \
      org.opencontainers.image.source="https://gitlab.com/final-year-project3354127/dkd-b2b"
COPY --from=build /src/service/target/b2b-trade-svc-*.jar /app/app.jar
COPY --from=build /src/build-info.properties /app/build-info.properties
EXPOSE 8080 9090
ENTRYPOINT ["java","-jar","/app/app.jar"]
