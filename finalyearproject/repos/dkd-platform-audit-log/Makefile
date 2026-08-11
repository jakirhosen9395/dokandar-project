.PHONY: run build vet test itest cover tidy vendor
VERSION    ?= $(shell cat VERSION)
GIT_SHA    ?= $(shell git rev-parse HEAD 2>/dev/null || echo unknown)
BUILD_TIME ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS = -s -w \
  -X gitlab.com/final-year-project3354127/audit-log-svc/internal/buildinfo.Version=$(VERSION) \
  -X gitlab.com/final-year-project3354127/audit-log-svc/internal/buildinfo.GitSha=$(GIT_SHA) \
  -X gitlab.com/final-year-project3354127/audit-log-svc/internal/buildinfo.BuildTime=$(BUILD_TIME)

tidy:   ; go mod tidy
vendor: ; go mod vendor
vet:    ; go vet ./...
build:  ; CGO_ENABLED=0 go build -trimpath -ldflags="$(LDFLAGS)" -o bin/server ./cmd/server
run:    ; go run ./cmd/server
test:   ; go test -race ./...
itest:  ; go test -race -tags integration ./...
cover:  ; go test -tags integration -covermode=atomic -coverpkg=./... -coverprofile=coverage.out ./... && go tool cover -func=coverage.out | tail -1
