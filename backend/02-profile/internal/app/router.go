package app

import (
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/google/uuid"
	apmchiv5 "go.elastic.co/apm/module/apmchiv5/v2"

	"github.com/dokandar/dokandar-profile/internal/observability"
)

// NewRouter wires the chi router with the platform-standard middleware
// chain. APM goes FIRST (outermost) per the platform's middleware-order
// rule — otherwise transactions never end. See observability.md §3.
func NewRouter() *chi.Mux {
	r := chi.NewRouter()
	r.Use(apmchiv5.Middleware())   // OUTERMOST — must be first.
	r.Use(requestID)
	r.Use(middleware.RealIP)
	r.Use(httpMetrics)
	r.Use(accessLog)               // structured per-request line
	r.NotFound(BareNotFound)
	r.MethodNotAllowed(MethodNotAllowed)
	return r
}

// accessLog emits a timestamped per-request line so `docker logs` shows WHEN a
// request happened. Format (day-month-year, matching the auth service), with no
// "INFO:" level prefix:
//
//   03-06-2026 07:20:25    103.197.153.50:58014 - "POST /api/v1/profile/me HTTP/1.1" 200 OK
//
// Quiet on the noisy LB-probe paths /ready and /metrics.
func accessLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rw := &statusRecorder{ResponseWriter: w, status: 200}
		next.ServeHTTP(rw, r)
		p := r.URL.Path
		if p == "/ready" || p == "/metrics" || p == "/health" {
			return
		}
		route := chi.RouteContext(r.Context()).RoutePattern() // templated route, never the raw URL
		if route == "" {
			route = p
		}
		// slog.InfoContext with the REQUEST context → the slog handler stamps the APM
		// trace context (ECS trace.id/transaction.id), so this access line correlates
		// with its transaction in Kibana APM and lands structured in the ES/Mongo sinks.
		slog.InfoContext(r.Context(), "access",
			"method", r.Method, "route", route, "status", rw.status,
			"duration_ms", float64(time.Since(start).Microseconds())/1000.0,
			"request_id", r.Header.Get("X-Request-Id"), "client_ip", r.RemoteAddr)
	})
}

// requestID echoes the inbound X-Request-Id (or generates one) so every
// log line and APM transaction can be correlated by it.
func requestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rid := r.Header.Get("X-Request-Id")
		if rid == "" {
			rid = strings.ReplaceAll(uuid.NewString(), "-", "")
		}
		r.Header.Set("X-Request-Id", rid)
		w.Header().Set("X-Request-Id", rid)
		next.ServeHTTP(w, r)
	})
}

// httpMetrics — minimal RED: requests + duration.
func httpMetrics(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t := time.Now()
		rw := &statusRecorder{ResponseWriter: w, status: 200}
		next.ServeHTTP(rw, r)
		route := chi.RouteContext(r.Context()).RoutePattern()
		if route == "" {
			route = "unmatched"
		}
		observability.HTTPRequests.WithLabelValues(r.Method, route, strconv.Itoa(rw.status)).Inc()
		observability.HTTPDuration.WithLabelValues(r.Method, route).Observe(time.Since(t).Seconds())
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}
