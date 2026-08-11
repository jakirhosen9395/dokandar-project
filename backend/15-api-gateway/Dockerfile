# syntax=docker/dockerfile:1
# DOKANDAR 15-api-gateway — Go / Echo v4 (stateless edge: JWKS verify, rate-limit, proxy).
FROM golang:1.25-bookworm AS build
WORKDIR /src
ENV CGO_ENABLED=0 GOFLAGS=-buildvcs=false GOPROXY=https://proxy.golang.org,direct
# Deps first for layer caching; the committed go.sum pins every checksum.
# go.mod deliberately lists direct requires only (see its header comment), so
# `go mod tidy` still runs after the source COPY to resolve the indirect
# requires — verified against the committed go.sum, never re-trusted blindly.
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
COPY CODE_VERSION ./CODE_VERSION
RUN go mod tidy
RUN go build -trimpath -ldflags="-s -w" -o /out/gateway ./cmd/gateway
RUN go build -trimpath -ldflags="-s -w" -o /out/healthcheck ./cmd/healthcheck

# Distroless runtime — no curl/shell; the HEALTHCHECK uses the static healthcheck
# binary (GET /ready, §16-h). data/ is bind-mounted read-only at runtime, not baked.
FROM gcr.io/distroless/static-debian12 AS runtime
WORKDIR /app
COPY --from=build /out/gateway     /app/gateway
COPY --from=build /out/healthcheck /app/healthcheck
COPY --from=build /src/CODE_VERSION /app/CODE_VERSION
USER 10001:10001
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 CMD ["/app/healthcheck"]
ENTRYPOINT ["/app/gateway"]
