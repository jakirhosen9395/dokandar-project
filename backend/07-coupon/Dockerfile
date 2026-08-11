# syntax=docker/dockerfile:1
# DOKANDAR 07-coupon — C#/.NET 10 / ASP.NET Core + EF Core 10 (REST 8080 + gRPC 9090).
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY coupon.csproj ./
COPY Protos ./Protos
RUN dotnet restore coupon.csproj
COPY . ./
RUN dotnet publish coupon.csproj -c Release -o /app --no-restore /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 10001 appuser \
 && useradd --uid 10001 --gid appuser --home-dir /app --no-create-home --shell /usr/sbin/nologin appuser
ENV ASPNETCORE_ENVIRONMENT=Production
# ASPNETCORE_URLS intentionally UNSET — Kestrel binds the dual ports in code (§16.1)
COPY --from=build /app ./
COPY CODE_VERSION ./CODE_VERSION
COPY migrations ./migrations
# data/ is NOT baked — tenant snapshots are bind-mounted ro at runtime (-v $(pwd)/data:/app/data:ro)
USER appuser
EXPOSE 8080 9090
HEALTHCHECK --interval=30s --timeout=3s --start-period=45s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${SERVICE_PORT:-8080}/ready" || exit 1
ENTRYPOINT ["dotnet", "coupon.dll"]
