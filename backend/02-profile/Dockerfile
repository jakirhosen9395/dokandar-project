# syntax=docker/dockerfile:1
# Multi-stage build: go.sum-pinned dependency download → go build → distroless.
# gRPC stubs are the COMMITTED internal/grpcserver/pb/*.pb.go (generated from
# proto/profile.proto with protoc v3.21.12 + protoc-gen-go v1.35.1 /
# protoc-gen-go-grpc v1.5.1) — no codegen at image-build time, so the Docker
# build is deterministic and matches the native build path exactly.

FROM golang:1.24 AS build
WORKDIR /src
ENV CGO_ENABLED=0 GOFLAGS=-buildvcs=false

# Dependency layer first: resolved strictly against the committed go.mod/go.sum
# (no `go mod tidy` re-resolution); cached until the manifests change.
COPY go.mod go.sum ./
RUN go mod download

COPY cmd ./cmd
COPY internal ./internal
COPY migrations ./migrations
COPY CODE_VERSION ./CODE_VERSION

RUN go build -trimpath -ldflags="-s -w" -o /out/profile     ./cmd/profile
RUN go build -trimpath -ldflags="-s -w" -o /out/healthcheck ./cmd/healthcheck

FROM gcr.io/distroless/static-debian12:nonroot AS runtime
WORKDIR /app
COPY --from=build /out/profile      /app/profile
COPY --from=build /out/healthcheck  /app/healthcheck
COPY --from=build /src/CODE_VERSION /app/CODE_VERSION
# `data/` is bind-mounted read-only at runtime; nothing baked into the image.
USER nonroot:nonroot
EXPOSE 8000 8001
HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
    CMD ["/app/healthcheck"]
ENTRYPOINT ["/app/profile"]
