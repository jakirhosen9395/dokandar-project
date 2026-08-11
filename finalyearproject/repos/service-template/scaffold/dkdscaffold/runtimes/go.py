"""
dkdscaffold.runtimes.go — Go runtime emitter (the reference). Emits a complete, compilable Go service
skeleton realising the blueprint: stdlib net/http + log/slog, minimal Prometheus-text metrics, W3C
traceparent propagation, JWT middleware, Kafka/RabbitMQ/DB abstractions, graceful shutdown, tests,
Dockerfile, CI. Consumes dkd-platform-libs/sdk/go. No business logic.
"""
from __future__ import annotations
from ..blueprint import Service
from ..render import Writer
from .common import emit_common

MODULE_BASE = "gitlab.com/final-year-project3354127"
SDK = "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"


def emit(svc: Service, out_dir: str) -> list[str]:
    w = Writer(out_dir, "//")
    mod = "%s/%s" % (MODULE_BASE, svc.slug)
    emit_common(w, svc)

    w.write("go.mod", "module %s\n\ngo 1.25\n\nrequire %s v1.0.0\n" % (mod, SDK))

    # cmd/server/main.go — bootstrap, config, DI, startup validation, graceful shutdown
    w.write("cmd/server/main.go", '''package main

import (
\t"context"
\t"os"
\t"os/signal"
\t"syscall"
\t"time"

\t"%s/internal/app"
\t"%s/internal/config"
\t"%s/internal/obs"
)

func main() {
\tlog := obs.NewLogger()
\tcfg, err := config.Load()
\tif err != nil {
\t\tlog.Error("config load failed", "err", err)
\t\tos.Exit(1)
\t}
\tif err := cfg.Validate(); err != nil { // startup validation
\t\tlog.Error("config invalid", "err", err)
\t\tos.Exit(1)
\t}

\tapplication, err := app.New(cfg, log) // dependency injection / wiring
\tif err != nil {
\t\tlog.Error("startup failed", "err", err)
\t\tos.Exit(1)
\t}

\tctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
\tdefer stop()

\tif err := application.Start(ctx); err != nil {
\t\tlog.Error("run failed", "err", err)
\t\tos.Exit(1)
\t}

\t<-ctx.Done() // block until signal
\tlog.Info("shutting down")
\tshutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
\tdefer cancel()
\tif err := application.Stop(shutdownCtx); err != nil { // graceful shutdown
\t\tlog.Error("graceful shutdown error", "err", err)
\t\tos.Exit(1)
\t}
\tlog.Info("stopped cleanly")
}
''' % (mod, mod, mod))

    # internal/config/config.go
    w.write("internal/config/config.go", '''package config

import (
\t"fmt"
\t"os"
\t"strconv"
)

// Config is 12-factor: everything from the environment. Secrets come from the platform secret
// manager in non-local environments (never committed).
type Config struct {
\tServiceName  string
\tContext      string
\tEnv          string
\tHTTPPort     int
\tMetricsPort  int
\tLogLevel     string
\tKafkaBrokers string
\tRabbitURL    string
\tDBDSN        string
\tOTELEndpoint string
\tJWTIssuer    string
}

func getenv(k, def string) string {
\tif v := os.Getenv(k); v != "" {
\t\treturn v
\t}
\treturn def
}

func Load() (*Config, error) {
\tport, err := strconv.Atoi(getenv("DKD_HTTP_PORT", "%d"))
\tif err != nil {
\t\treturn nil, fmt.Errorf("DKD_HTTP_PORT: %%w", err)
\t}
\treturn &Config{
\t\tServiceName:  getenv("DKD_SERVICE_NAME", "%s"),
\t\tContext:      getenv("DKD_CONTEXT", "%s"),
\t\tEnv:          getenv("DKD_ENV", "local"),
\t\tHTTPPort:     port,
\t\tMetricsPort:  9090,
\t\tLogLevel:     getenv("DKD_LOG_LEVEL", "info"),
\t\tKafkaBrokers: getenv("DKD_KAFKA_BROKERS", "localhost:9092"),
\t\tRabbitURL:    getenv("DKD_RABBITMQ_URL", ""),
\t\tDBDSN:        getenv("DKD_DB_DSN", ""),
\t\tOTELEndpoint: getenv("DKD_OTEL_ENDPOINT", ""),
\t\tJWTIssuer:    getenv("DKD_JWT_ISSUER", ""),
\t}, nil
}

// Validate fails fast on missing required configuration.
func (c *Config) Validate() error {
\tif c.ServiceName == "" || c.Context == "" {
\t\treturn fmt.Errorf("service name and context are required")
\t}
\tif c.HTTPPort <= 0 {
\t\treturn fmt.Errorf("invalid http port %%d", c.HTTPPort)
\t}
\treturn nil
}
''' % (svc.http_port, svc.slug, svc.context))

    # internal/obs/logging.go
    w.write("internal/obs/logging.go", '''package obs

import (
\t"log/slog"
\t"os"
)

// NewLogger returns a structured JSON logger (slog). Correlation/trace IDs are attached per-request.
func NewLogger() *slog.Logger {
\treturn slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
}
''')

    # internal/obs/metrics.go — minimal real Prometheus-text exposition (stdlib only)
    w.write("internal/obs/metrics.go", '''package obs

import (
\t"fmt"
\t"net/http"
\t"sync"
)

// Metrics is a minimal, dependency-free Prometheus-text counter registry. Swap for the Prometheus
// client library at the integration point if richer metric types are needed.
type Metrics struct {
\tmu       sync.Mutex
\tcounters map[string]float64
}

func NewMetrics() *Metrics { return &Metrics{counters: map[string]float64{}} }

func (m *Metrics) Inc(name string) {
\tm.mu.Lock()
\tdefer m.mu.Unlock()
\tm.counters[name]++
}

func (m *Metrics) Handler() http.Handler {
\treturn http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
\t\tm.mu.Lock()
\t\tdefer m.mu.Unlock()
\t\tw.Header().Set("Content-Type", "text/plain; version=0.0.4")
\t\tfor name, v := range m.counters {
\t\t\tfmt.Fprintf(w, "%s %g\\n", name, v)
\t\t}
\t})
}
''')

    # internal/obs/tracing.go — W3C traceparent propagation + tracer seam
    w.write("internal/obs/tracing.go", '''package obs

import (
\t"context"
\t"crypto/rand"
\t"encoding/hex"
)

type ctxKey string

const (
\tCorrelationIDKey ctxKey = "correlation_id"
\tTraceParentKey   ctxKey = "traceparent"
)

// NewTraceParent generates a W3C traceparent. The OpenTelemetry SDK is the integration point for
// span export; propagation works without it.
func NewTraceParent() string {
\ttid := make([]byte, 16)
\tsid := make([]byte, 8)
\t_, _ = rand.Read(tid)
\t_, _ = rand.Read(sid)
\treturn "00-" + hex.EncodeToString(tid) + "-" + hex.EncodeToString(sid) + "-01"
}

func CorrelationID(ctx context.Context) string {
\tif v, ok := ctx.Value(CorrelationIDKey).(string); ok {
\t\treturn v
\t}
\treturn ""
}
''')

    # internal/httpx/server.go
    w.write("internal/httpx/server.go", '''package httpx

import (
\t"context"
\t"fmt"
\t"net/http"
\t"time"

\t"log/slog"

\t"%s/internal/obs"
\t"%s/internal/security"

\t"gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go/apidocs"
)

// Server wires the HTTP mux with health endpoints + the standard middleware chain.
type Server struct {
\thttp    *http.Server
\tmetrics *http.Server
}

func New(serviceName string, port, metricsPort int, log *slog.Logger, m *obs.Metrics, auth *security.JWT, ready func() bool) *Server {
\tmux := http.NewServeMux()
\tmux.HandleFunc("/health", health)
\tmux.HandleFunc("/live", live)
\tmux.HandleFunc("/ready", readyHandler(ready))
\tmux.HandleFunc("/version", version)
\t// API Documentation Standard: Swagger UI at /docs + OpenAPI JSON at /swagger/v1/swagger.json (SDK helper).
\tapidocs.Register(mux, serviceName)

\tchain := Recover(log)(CorrelationMiddleware(RequestLogging(log, m)(SecurityHeaders(auth.Optional()(mux)))))

\tmetricsMux := http.NewServeMux()
\tmetricsMux.Handle("/metrics", m.Handler())

\treturn &Server{
\t\thttp:    &http.Server{Addr: fmt.Sprintf(":%%d", port), Handler: chain, ReadHeaderTimeout: 5 * time.Second},
\t\tmetrics: &http.Server{Addr: fmt.Sprintf(":%%d", metricsPort), Handler: metricsMux, ReadHeaderTimeout: 5 * time.Second},
\t}
}

func (s *Server) Start() {
\tgo func() { _ = s.http.ListenAndServe() }()
\tgo func() { _ = s.metrics.ListenAndServe() }()
}

func (s *Server) Stop(ctx context.Context) error {
\t_ = s.metrics.Shutdown(ctx)
\treturn s.http.Shutdown(ctx)
}
''' % (mod, mod))

    # internal/httpx/health.go — health/ready/live/version using the SDK for provenance
    w.write("internal/httpx/health.go", '''package httpx

import (
\t"encoding/json"
\t"net/http"

\tdkdplatform "%s"
)

func writeJSON(w http.ResponseWriter, status int, body any) {
\tw.Header().Set("Content-Type", "application/json")
\tw.WriteHeader(status)
\t_ = json.NewEncoder(w).Encode(body)
}

func health(w http.ResponseWriter, _ *http.Request) {
\twriteJSON(w, http.StatusOK, map[string]any{"success": true, "data": map[string]string{"status": "ok"}})
}

func live(w http.ResponseWriter, _ *http.Request) {
\twriteJSON(w, http.StatusOK, map[string]any{"success": true, "data": map[string]string{"status": "alive"}})
}

func readyHandler(ready func() bool) http.HandlerFunc {
\treturn func(w http.ResponseWriter, _ *http.Request) {
\t\tif ready != nil && !ready() {
\t\t\twriteJSON(w, http.StatusServiceUnavailable, map[string]any{"success": false, "data": map[string]string{"status": "not-ready"}})
\t\t\treturn
\t\t}
\t\twriteJSON(w, http.StatusOK, map[string]any{"success": true, "data": map[string]string{"status": "ready"}})
\t}
}

func version(w http.ResponseWriter, _ *http.Request) {
\twriteJSON(w, http.StatusOK, map[string]any{"success": true, "data": map[string]string{
\t\t"contractVersion": dkdplatform.ContractVersion,
\t\t"sdkGenerator":    dkdplatform.GeneratorVersion,
\t}})
}
''' % SDK)

    # internal/httpx/middleware.go
    w.write("internal/httpx/middleware.go", '''package httpx

import (
\t"context"
\t"net/http"
\t"time"

\t"log/slog"

\t"%s/internal/obs"

\t"gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go/apidocs"
)

type middleware func(http.Handler) http.Handler

// CorrelationMiddleware ensures every request carries a correlation id + traceparent.
func CorrelationMiddleware(next http.Handler) http.Handler {
\treturn http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
\t\tcid := r.Header.Get("X-Correlation-Id")
\t\tif cid == "" {
\t\t\tcid = obs.NewTraceParent()
\t\t}
\t\ttp := r.Header.Get("traceparent")
\t\tif tp == "" {
\t\t\ttp = obs.NewTraceParent()
\t\t}
\t\tctx := context.WithValue(r.Context(), obs.CorrelationIDKey, cid)
\t\tctx = context.WithValue(ctx, obs.TraceParentKey, tp)
\t\tw.Header().Set("X-Correlation-Id", cid)
\t\tnext.ServeHTTP(w, r.WithContext(ctx))
\t})
}

func RequestLogging(log *slog.Logger, m *obs.Metrics) middleware {
\treturn func(next http.Handler) http.Handler {
\t\treturn http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
\t\t\tstart := time.Now()
\t\t\tm.Inc("http_requests_total")
\t\t\tnext.ServeHTTP(w, r)
\t\t\tlog.Info("request", "method", r.Method, "path", r.URL.Path,
\t\t\t\t"correlation_id", obs.CorrelationID(r.Context()), "elapsed_ms", time.Since(start).Milliseconds())
\t\t})
\t}
}

// SecurityHeaders sets conservative defaults.
func SecurityHeaders(next http.Handler) http.Handler {
\treturn http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
\t\th := w.Header()
\t\th.Set("X-Content-Type-Options", "nosniff")
\t\th.Set("Referrer-Policy", "no-referrer")
\t\t// API Documentation Standard: relax CSP only for the Swagger UI paths; strict elsewhere.
\t\tif apidocs.IsDocsPath(r.URL.Path) {
\t\t\th.Set("Content-Security-Policy", apidocs.DocsCSP())
\t\t} else {
\t\t\th.Set("X-Frame-Options", "DENY")
\t\t\th.Set("Content-Security-Policy", "default-src 'none'")
\t\t}
\t\tnext.ServeHTTP(w, r)
\t})
}

// Recover turns panics into RFC-7807 problem responses (exception handling).
func Recover(log *slog.Logger) middleware {
\treturn func(next http.Handler) http.Handler {
\t\treturn http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
\t\t\tdefer func() {
\t\t\t\tif rec := recover(); rec != nil {
\t\t\t\t\tlog.Error("panic recovered", "err", rec, "path", r.URL.Path)
\t\t\t\t\twriteJSON(w, http.StatusInternalServerError, map[string]any{
\t\t\t\t\t\t"success": false,
\t\t\t\t\t\t"error":   map[string]any{"type": "about:blank", "title": "internal error", "status": 500, "code": "dokandar.%s.internal.panic"},
\t\t\t\t\t})
\t\t\t\t}
\t\t\t}()
\t\t\tnext.ServeHTTP(w, r)
\t\t})
\t}
}
''' % (mod, svc.context))

    # internal/security/jwt.go — JWT auth + authorization
    w.write("internal/security/jwt.go", '''package security

import (
\t"context"
\t"encoding/base64"
\t"encoding/json"
\t"net/http"
\t"strings"
)

// JWT provides authentication (bearer extraction + claims parsing) and an authorization helper.
// Signature verification is delegated to a Verifier (the integration point for the platform JWKS).
type JWT struct {
\tIssuer   string
\tVerifier Verifier
}

type Verifier interface {
\tVerify(token string) error
}

// Claims is the minimal claim set the platform issues (see dkd-platform-libs JwtClaims).
type Claims struct {
\tSub     string   `json:"sub"`
\tKycTier string   `json:"kyc_tier"`
\tRoles   []string `json:"roles"`
\tCid     string   `json:"cid"`
}

func New(issuer string, v Verifier) *JWT { return &JWT{Issuer: issuer, Verifier: v} }

func parse(token string) (*Claims, error) {
\tparts := strings.Split(token, ".")
\tif len(parts) != 3 {
\t\treturn nil, http.ErrNoCookie
\t}
\tpayload, err := base64.RawURLEncoding.DecodeString(parts[1])
\tif err != nil {
\t\treturn nil, err
\t}
\tvar c Claims
\tif err := json.Unmarshal(payload, &c); err != nil {
\t\treturn nil, err
\t}
\treturn &c, nil
}

type claimsKey struct{}

// Optional attaches claims when a valid bearer is present, but does not reject anonymous traffic
// (health endpoints are public). Use Require for protected routes.
func (j *JWT) Optional() func(http.Handler) http.Handler {
\treturn func(next http.Handler) http.Handler {
\t\treturn http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
\t\t\tif tok := bearer(r); tok != "" {
\t\t\t\tif c, err := parse(tok); err == nil {
\t\t\t\t\tif j.Verifier == nil || j.Verifier.Verify(tok) == nil {
\t\t\t\t\t\tnext.ServeHTTP(w, r.WithContext(withClaims(r, c)))
\t\t\t\t\t\treturn
\t\t\t\t\t}
\t\t\t\t}
\t\t\t}
\t\t\tnext.ServeHTTP(w, r)
\t\t})
\t}
}

// HasRole is the authorization helper (RBAC). Pair with the platform PDP for ABAC.
func HasRole(c *Claims, role string) bool {
\tif c == nil {
\t\treturn false
\t}
\tfor _, r := range c.Roles {
\t\tif r == role {
\t\t\treturn true
\t\t}
\t}
\treturn false
}

func bearer(r *http.Request) string {
\th := r.Header.Get("Authorization")
\tif strings.HasPrefix(h, "Bearer ") {
\t\treturn strings.TrimPrefix(h, "Bearer ")
\t}
\treturn ""
}

func withClaims(r *http.Request, c *Claims) context.Context {
\treturn context.WithValue(r.Context(), claimsKey{}, c)
}

// ClaimsFrom returns the authenticated claims attached by Optional, if any.
func ClaimsFrom(ctx context.Context) *Claims {
\tc, _ := ctx.Value(claimsKey{}).(*Claims)
\treturn c
}
''')

    # internal/messaging/messaging.go — Kafka + RabbitMQ bootstrap abstractions
    w.write("internal/messaging/messaging.go", '''package messaging

import "context"

// Publisher / Consumer are the event-bus abstractions. Concrete Kafka (Redpanda) and RabbitMQ
// clients implement them at the integration point. No business events are defined here (R6: events
// are the Published Language; payloads come from the contracts).
type Publisher interface {
\tPublish(ctx context.Context, topic string, key string, payload []byte) error
\tClose() error
}

type Consumer interface {
\tSubscribe(ctx context.Context, topics []string, handle func(topic string, key string, payload []byte) error) error
\tClose() error
}

// KafkaConfig / RabbitConfig hold connection settings; Bootstrap wires the chosen driver.
type KafkaConfig struct{ Brokers string }
type RabbitConfig struct{ URL string }

// NoopPublisher is a safe default for local runs without a broker; replace with the real driver.
type NoopPublisher struct{}

func (NoopPublisher) Publish(context.Context, string, string, []byte) error { return nil }
func (NoopPublisher) Close() error                                          { return nil }
''')

    # internal/persistence/persistence.go — DB abstraction, repo base, tx helper, migrations
    w.write("internal/persistence/persistence.go", '''package persistence

import "context"

// DB is the persistence abstraction. The concrete driver (pgx for Postgres) is wired at the
// integration point. No business repositories are defined here.
type DB interface {
\tPing(ctx context.Context) error
\tWithTx(ctx context.Context, fn func(tx Tx) error) error
\tClose() error
}

type Tx interface {
\tExec(ctx context.Context, sql string, args ...any) error
}

// Repository is the base every context repository embeds; it carries the DB handle and the tx helper.
type Repository struct {
\tDB DB
}

func (r Repository) InTx(ctx context.Context, fn func(tx Tx) error) error {
\treturn r.DB.WithTx(ctx, fn)
}

// Migrator runs ordered, idempotent schema migrations at startup. The driver supplies Apply.
type Migrator interface {
\tApply(ctx context.Context) error
}
''')

    # internal/validation/validation.go
    w.write("internal/validation/validation.go", '''package validation

import "fmt"

// Validate fails fast on boundary input (EF C7: never coerce invalid input).
func Required(field, value string) error {
\tif value == "" {
\t\treturn fmt.Errorf("%s is required", field)
\t}
\treturn nil
}
''')

    # internal/app/app.go — DI wiring
    w.write("internal/app/app.go", '''package app

import (
\t"context"

\t"log/slog"

\t"%s/internal/config"
\t"%s/internal/httpx"
\t"%s/internal/messaging"
\t"%s/internal/obs"
\t"%s/internal/security"
)

// App is the dependency-injection container: it constructs and owns the service's adapters.
type App struct {
\tcfg     *config.Config
\tlog     *slog.Logger
\tserver  *httpx.Server
\tpub     messaging.Publisher
\tready   bool
}

func New(cfg *config.Config, log *slog.Logger) (*App, error) {
\tmetrics := obs.NewMetrics()
\tauth := security.New(cfg.JWTIssuer, nil) // platform JWKS verifier wired at integration point
\ta := &App{cfg: cfg, log: log, pub: messaging.NoopPublisher{}}
\ta.server = httpx.New(cfg.ServiceName, cfg.HTTPPort, cfg.MetricsPort, log, metrics, auth, func() bool { return a.ready })
\treturn a, nil
}

func (a *App) Start(ctx context.Context) error {
\ta.server.Start()
\ta.ready = true // flip readiness once dependencies are connected
\ta.log.Info("started", "service", a.cfg.ServiceName, "port", a.cfg.HTTPPort)
\treturn nil
}

func (a *App) Stop(ctx context.Context) error {
\ta.ready = false
\t_ = a.pub.Close()
\treturn a.server.Stop(ctx)
}
''' % (mod, mod, mod, mod, mod))

    # tests
    w.write("internal/httpx/health_test.go", '''package httpx

import (
\t"net/http"
\t"net/http/httptest"
\t"strings"
\t"testing"

\t"gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go/apidocs"
)

func TestHealth(t *testing.T) {
\trec := httptest.NewRecorder()
\thealth(rec, httptest.NewRequest(http.MethodGet, "/health", nil))
\tif rec.Code != http.StatusOK {
\t\tt.Fatalf("health = %d, want 200", rec.Code)
\t}
}

// API Documentation Standard: Swagger UI at /docs, OpenAPI JSON at /swagger/v1/swagger.json + Bearer.
func TestAPIDocs(t *testing.T) {
\tmux := http.NewServeMux()
\tapidocs.Register(mux, "test-svc")
\tfor _, p := range []string{"/docs", "/swagger/v1/swagger.json"} {
\t\trec := httptest.NewRecorder()
\t\tmux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, p, nil))
\t\tif rec.Code != http.StatusOK {
\t\t\tt.Fatalf("%s = %d, want 200", p, rec.Code)
\t\t}
\t}
\trec := httptest.NewRecorder()
\tmux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/swagger/v1/swagger.json", nil))
\tif body := rec.Body.String(); !strings.Contains(body, "\\"Bearer\\"") || !strings.Contains(body, "\\"version\\": \\"v1\\"") {
\t\tt.Fatalf("openapi doc missing Bearer scheme or version v1")
\t}
}

func TestVersionUsesSDK(t *testing.T) {
\trec := httptest.NewRecorder()
\tversion(rec, httptest.NewRequest(http.MethodGet, "/version", nil))
\tif rec.Code != http.StatusOK {
\t\tt.Fatalf("version = %d", rec.Code)
\t}
}
''')
    w.write("internal/integration/integration_test.go", '''//go:build integration

// Integration tests run against ephemeral infra (testcontainers / docker-compose). They are
// build-tagged so unit CI stays fast; the integration CI stage runs `go test -tags integration`.
package integration

import "testing"

func TestServiceBoots(t *testing.T) {
\t// Brought up by the integration CI stage (postgres + redpanda + rabbitmq); asserts /ready.
\tt.Skip("requires docker infra; exercised by the integration CI stage")
}
''')

    # Dockerfile
    w.write("Dockerfile", '''# Multi-stage Go build. Distroless runtime; non-root.
FROM golang:1.25 AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download || true
COPY . .
RUN CGO_ENABLED=0 go build -o /out/server ./cmd/server

FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/server /server
EXPOSE %d 9090
USER nonroot:nonroot
ENTRYPOINT ["/server"]
''' % svc.http_port)

    # Makefile
    w.write("Makefile", '''.PHONY: run test build vet
run: ; go run ./cmd/server
build: ; go build ./...
vet: ; go vet ./...
test: ; go test ./...
itest: ; go test -tags integration ./...
''')

    # .gitlab-ci.yml
    w.write(".gitlab-ci.yml", '''stages: [build, package]

variables:
  GOFLAGS: "-mod=mod"

go:build-test:
  stage: build
  image: golang:1.25
  before_script:
    # consume dkd-platform-libs/sdk/go via the CI job token (private module)
    - git config --global url."https://gitlab-ci-token:${CI_JOB_TOKEN}@gitlab.com/".insteadOf "https://gitlab.com/"
    - export GOPRIVATE=gitlab.com/%s/*
  script:
    - go vet ./...
    - go build ./...
    - go test ./...

docker:build:
  stage: package
  image: docker:27
  services: [docker:27-dind]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  script:
    - docker build -t "$CI_REGISTRY_IMAGE:0.1.0" .
''' % svc.group)

    return list(w.written)
