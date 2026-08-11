# Multi-stage C# / .NET 10 build for identity-svc.
# Stage 1 (build): SDK image compiles + publishes; Stage 2 (runtime): ASP.NET runtime, non-root.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Restore in a cache-efficient layer: copy the project files (incl. the vendored SDK it references).
COPY IdentitySvc.csproj ./
COPY sdk/Dkd.Platform/Dkd.Platform.csproj sdk/Dkd.Platform/
RUN dotnet restore IdentitySvc.csproj

# Copy the rest and publish (Content migrations/*.sql are emitted to /out/migrations).
COPY . .
RUN dotnet publish IdentitySvc.csproj -c Release -o /out --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
# ID-06 / CC-CONS-1: single-SHA provenance — thread the deploy build-args into env so /version can
# report the real gitSha/version/buildTime (identity was the sole service without a gitSha).
ARG GIT_SHA=unknown
ARG VERSION=0.0.0-dev
ARG BUILD_TIME=unknown
ENV DKD_GIT_SHA=$GIT_SHA \
    DKD_VERSION=$VERSION \
    DKD_BUILD_TIME=$BUILD_TIME
WORKDIR /app
# curl for container healthchecks (HTTP probes in k8s do not need it, but Compose healthcheck does).
USER root
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
COPY --from=build /out .
# HEALTHCHECK — AUD/ID DoD: container-level liveness (k8s probes cover in-cluster; this covers Compose).
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
  CMD curl -sf http://127.0.0.1:8080/health || exit 1

EXPOSE 8080 8081 9090
# Built-in non-root 'app' user (uid 1654) ships in the aspnet image.
USER app
ENTRYPOINT ["dotnet", "IdentitySvc.dll"]
