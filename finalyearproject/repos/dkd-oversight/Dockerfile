# syntax=docker/dockerfile:1
# oversight-svc — Context #11 (Government & Regulatory Oversight, R5/BR-038).
ARG GIT_SHA=unknown
ARG VERSION=0.0.0-dev
ARG BUILD_TIME=unknown

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY OversightSvc.csproj ./
COPY sdk/Dkd.Platform/Dkd.Platform.csproj sdk/Dkd.Platform/
RUN dotnet restore OversightSvc.csproj
COPY . .
RUN dotnet publish OversightSvc.csproj -c Release -o /out --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
ARG GIT_SHA
ARG VERSION
ARG BUILD_TIME
LABEL org.opencontainers.image.title="oversight-svc" \
      org.opencontainers.image.description="DOKANDAR Context #11 Government Oversight — read models + four-eyes directives (R5)" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${BUILD_TIME}" \
      org.opencontainers.image.source="https://gitlab.com/final-year-project3354127/dkd-oversight"
WORKDIR /app
COPY --from=build /out .
RUN printf '{"version":"%s","gitSha":"%s","buildTime":"%s"}' "$VERSION" "$GIT_SHA" "$BUILD_TIME" > /app/build-info.json
EXPOSE 8080 9090
ENTRYPOINT ["dotnet","oversight-svc.dll"]
