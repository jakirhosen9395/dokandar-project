# syntax=docker/dockerfile:1
# platform-services — Context #13 (scheduler-svc + notification-svc, one image, two binaries).
ARG GIT_SHA=unknown
ARG VERSION=0.0.0-dev
ARG BUILD_TIME=unknown

FROM golang:1.25 AS build
ARG GIT_SHA
ARG VERSION
ARG BUILD_TIME
WORKDIR /src
COPY . .
ENV CGO_ENABLED=0 GOFLAGS=-mod=vendor
RUN go build -buildvcs=false -ldflags "-X gitlab.com/final-year-project3354127/platform-services/internal/buildinfo.Version=$VERSION -X gitlab.com/final-year-project3354127/platform-services/internal/buildinfo.GitSha=$GIT_SHA -X gitlab.com/final-year-project3354127/platform-services/internal/buildinfo.BuildTime=$BUILD_TIME" -o /out/scheduler-svc ./cmd/scheduler \
 && go build -buildvcs=false -ldflags "-X gitlab.com/final-year-project3354127/platform-services/internal/buildinfo.Version=$VERSION -X gitlab.com/final-year-project3354127/platform-services/internal/buildinfo.GitSha=$GIT_SHA -X gitlab.com/final-year-project3354127/platform-services/internal/buildinfo.BuildTime=$BUILD_TIME" -o /out/notification-svc ./cmd/notification

FROM gcr.io/distroless/static-debian12:nonroot
ARG GIT_SHA
ARG VERSION
ARG BUILD_TIME
LABEL org.opencontainers.image.title="platform-services" \
      org.opencontainers.image.description="DOKANDAR Context #13 — scheduler-svc (Saga 3 clock) + notification-svc (R8 fabric)" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${BUILD_TIME}" \
      org.opencontainers.image.source="https://gitlab.com/final-year-project3354127/dkd-platform-services"
COPY --from=build /out/scheduler-svc /scheduler-svc
COPY --from=build /out/notification-svc /notification-svc
EXPOSE 8080 9090
ENTRYPOINT ["/scheduler-svc"]
