# syntax=docker/dockerfile:1
# finance-ledger-svc — Context #8 (R2 isolated Finance core). Single-source provenance:
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
LABEL org.opencontainers.image.title="finance-ledger-svc" \
      org.opencontainers.image.description="DOKANDAR Context #8 Finance — R2 isolated int64-poisha double-entry ledger + escrow" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${BUILD_TIME}" \
      org.opencontainers.image.source="https://gitlab.com/final-year-project3354127/dkd-finance"
COPY --from=build /src/service/target/finance-ledger-svc-*.jar /app/app.jar
COPY --from=build /src/build-info.properties /app/build-info.properties
EXPOSE 8080 9090
ENTRYPOINT ["java","-jar","/app/app.jar"]
