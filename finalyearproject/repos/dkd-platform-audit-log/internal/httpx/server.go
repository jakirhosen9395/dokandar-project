package httpx

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"

	"log/slog"

	"gitlab.com/final-year-project3354127/audit-log-svc/internal/obs"
	"gitlab.com/final-year-project3354127/audit-log-svc/internal/security"
)

// Server wires the HTTP mux with health endpoints + the standard middleware chain.
type Server struct {
	http    *http.Server
	metrics *http.Server
	log     *slog.Logger
}

func New(serviceName string, port, metricsPort int, log *slog.Logger, m *obs.Metrics, auth *security.JWT, ready func() bool) *Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", health)
	mux.HandleFunc("/live", live)
	mux.HandleFunc("/ready", readyHandler(ready))
	mux.HandleFunc("/version", version)
	// API Documentation Standard: Swagger UI at /docs + OpenAPI JSON at /swagger/v1/swagger.json.
	// Hand-rolled in-repo (see openapi.go) — the SDK apidocs package does not exist at the pinned v1.3.0.
	registerDocs(mux, serviceName)

	chain := Recover(log)(CorrelationMiddleware(RequestLogging(log, m)(SecurityHeaders(auth.Optional()(mux)))))

	metricsMux := http.NewServeMux()
	metricsMux.Handle("/metrics", m.Handler())

	return &Server{
		http:    &http.Server{Addr: fmt.Sprintf(":%d", port), Handler: chain, ReadHeaderTimeout: 5 * time.Second},
		metrics: &http.Server{Addr: fmt.Sprintf(":%d", metricsPort), Handler: metricsMux, ReadHeaderTimeout: 5 * time.Second},
		log:     log,
	}
}

// Start serves both listeners. A bind/permission failure at startup is surfaced (not silently
// swallowed); http.ErrServerClosed on graceful shutdown is expected and ignored.
func (s *Server) Start() {
	go func() {
		if err := s.http.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			s.log.Error("HTTP server failed", "err", err)
		}
	}()
	go func() {
		if err := s.metrics.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			s.log.Error("metrics server failed", "err", err)
		}
	}()
}

func (s *Server) Stop(ctx context.Context) error {
	if err := s.metrics.Shutdown(ctx); err != nil {
		s.log.Warn("metrics server shutdown error", "err", err)
	}
	return s.http.Shutdown(ctx)
}
