# syntax=docker/dockerfile:1
# Multi-stage Go build; distroless non-root runtime. Provenance is SINGLE-SOURCED: the SHA / version /
# build-time arrive once as build-args (CI passes them from $CI_COMMIT_SHA / $CI_COMMIT_TAG) and are
# threaded into BOTH the ldflags and the OCI image labels. No stage re-derives them (no in-image git/date).
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
RUN go build -trimpath \
      -ldflags="-s -w \
        -X gitlab.com/final-year-project3354127/audit-log-svc/internal/buildinfo.Version=${VERSION} \
        -X gitlab.com/final-year-project3354127/audit-log-svc/internal/buildinfo.GitSha=${GIT_SHA} \
        -X gitlab.com/final-year-project3354127/audit-log-svc/internal/buildinfo.BuildTime=${BUILD_TIME}" \
      -o /out/server ./cmd/server
RUN printf '%s\n' "${VERSION}" > /out/VERSION \
 && printf '{"version":"%s","gitSha":"%s","buildTime":"%s"}\n' "${VERSION}" "${GIT_SHA}" "${BUILD_TIME}" > /out/build-info.json

FROM gcr.io/distroless/static:nonroot
ARG GIT_SHA
ARG VERSION
ARG BUILD_TIME
LABEL org.opencontainers.image.title="audit-log-svc" \
      org.opencontainers.image.description="DOKANDAR Context #13 Platform — append-only OHS audit sink (R6)" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${BUILD_TIME}" \
      org.opencontainers.image.source="https://gitlab.com/final-year-project3354127/dkd-platform-audit-log"
COPY --from=build /out/server /server
COPY --from=build /out/VERSION /app/VERSION
COPY --from=build /out/build-info.json /app/build-info.json
EXPOSE 8080 9090
# AUD-03: distroless-safe container HEALTHCHECK via the binary's own -health mode (no shell/curl needed).
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 CMD ["/server", "-health"]
USER nonroot:nonroot
ENTRYPOINT ["/server"]
