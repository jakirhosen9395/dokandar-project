# syntax=docker/dockerfile:1
# ---- build stage --------------------------------------------------------------
FROM golang:1.25-bookworm AS build
WORKDIR /src
ENV CGO_ENABLED=0 GOFLAGS=-buildvcs=false GOPROXY=https://proxy.golang.org,direct

# protoc + the Go gRPC plugins (versions matched to the protobuf runtime).
RUN apt-get update && \
    apt-get install -y --no-install-recommends protobuf-compiler ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.11 && \
    go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.5.1
ENV PATH="/root/go/bin:${PATH}"

# Dependency manifests first (layer caching). The committed go.sum pins module
# hashes, so every module pulled below is verified against it (no TOFU).
COPY go.mod go.sum ./
RUN go mod download

# App source (top-level migrations/ is NOT copied: the binary embeds
# internal/db/migrations_embed via go:embed).
COPY cmd ./cmd
COPY internal ./internal
COPY proto ./proto
COPY CODE_VERSION ./CODE_VERSION

# Generate the gRPC stubs into internal/grpcsrv/walletpb (paths=source_relative
# + the proto's go_package `;walletpb` set the package name).
RUN mkdir -p internal/grpcsrv/walletpb && \
    protoc -I proto \
      --go_out=internal/grpcsrv/walletpb      --go_opt=paths=source_relative \
      --go-grpc_out=internal/grpcsrv/walletpb --go-grpc_opt=paths=source_relative \
      wallet.proto

# go.mod lists only direct deps (no `// indirect` block), so a -mod=readonly
# build would fail; tidy completes the module graph — every module is verified
# against the committed go.sum hashes above. Do not remove without tidying go.mod.
RUN go mod tidy
RUN go build -trimpath -ldflags="-s -w" -o /out/wallet ./cmd/wallet

# ---- runtime stage ------------------------------------------------------------
FROM debian:bookworm-slim AS runtime
WORKDIR /app
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    useradd --uid 10001 --create-home appuser
COPY --from=build /out/wallet       /app/wallet
COPY --from=build /src/CODE_VERSION /app/CODE_VERSION
# migrations are embedded into the binary via go:embed — not copied here.
USER 10001
EXPOSE 8080 8001
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
    CMD curl -fsS "http://localhost:${SERVICE_PORT:-8080}/ready" >/dev/null || exit 1
ENTRYPOINT ["/app/wallet"]
