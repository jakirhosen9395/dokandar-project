package httpx

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"time"

	"log/slog"

	"gitlab.com/final-year-project3354127/inventory-svc/internal/obs"
	"gitlab.com/final-year-project3354127/inventory-svc/internal/security"
)

// Server wires the HTTP mux with health endpoints + the standard middleware chain.
type Server struct {
	http    *http.Server
	metrics *http.Server
	log     *slog.Logger
}

func New(serviceName string, port, metricsPort int, log *slog.Logger, m *obs.Metrics, auth *security.JWT, ready func() bool, registrars ...func(*http.ServeMux)) *Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", health)
	mux.HandleFunc("/live", live)
	mux.HandleFunc("/ready", readyHandler(ready))
	mux.HandleFunc("/version", version)
	for _, reg := range registrars {
		reg(mux)
	}
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

// Start binds both listeners synchronously (a bind failure is returned to the caller, never
// swallowed in a goroutine) and then serves them; http.ErrServerClosed on shutdown is expected.
func (s *Server) Start() error {
	httpLn, err := net.Listen("tcp", s.http.Addr)
	if err != nil {
		return fmt.Errorf("httpx: bind %s: %w", s.http.Addr, err)
	}
	metricsLn, err := net.Listen("tcp", s.metrics.Addr)
	if err != nil {
		_ = httpLn.Close()
		return fmt.Errorf("httpx: bind %s: %w", s.metrics.Addr, err)
	}
	go func() {
		if err := s.http.Serve(httpLn); err != nil && !errors.Is(err, http.ErrServerClosed) {
			s.log.Error("HTTP server failed", "err", err)
		}
	}()
	go func() {
		if err := s.metrics.Serve(metricsLn); err != nil && !errors.Is(err, http.ErrServerClosed) {
			s.log.Error("metrics server failed", "err", err)
		}
	}()
	return nil
}

func (s *Server) Stop(ctx context.Context) error {
	if err := s.metrics.Shutdown(ctx); err != nil {
		s.log.Warn("metrics server shutdown error", "err", err)
	}
	return s.http.Shutdown(ctx)
}
