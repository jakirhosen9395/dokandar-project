package httpx

import (
	"context"
	"net/http"
	"time"

	"log/slog"

	"go.opentelemetry.io/otel"

	"gitlab.com/final-year-project3354127/platform-services/internal/obs"
)

type middleware func(http.Handler) http.Handler

// CorrelationMiddleware ensures every request carries a correlation id + traceparent.
func CorrelationMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cid := r.Header.Get("X-Correlation-Id")
		if cid == "" {
			cid = obs.NewTraceParent()
		}
		tp := r.Header.Get("traceparent")
		if tp == "" {
			tp = obs.NewTraceParent()
		}
		ctx := context.WithValue(r.Context(), obs.CorrelationIDKey, cid)
		ctx = context.WithValue(ctx, obs.TraceParentKey, tp)
		w.Header().Set("X-Correlation-Id", cid)
		// PLAT-08: a real OTel span per request (global provider installed by obs.InitTracer).
		ctx, span := otel.Tracer("platform-svc").Start(ctx, r.Method+" "+r.URL.Path)
		defer span.End()
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func RequestLogging(log *slog.Logger, m *obs.Metrics) middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			m.Inc("http_requests_total")
			next.ServeHTTP(w, r)
			log.Info("request", "method", r.Method, "path", r.URL.Path,
				"correlation_id", obs.CorrelationID(r.Context()), "elapsed_ms", time.Since(start).Milliseconds())
		})
	}
}

// SecurityHeaders sets conservative defaults.
func SecurityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		// API Documentation Standard: relax CSP only for the Swagger UI paths; strict elsewhere.
		if isDocsPath(r.URL.Path) {
			h.Set("Content-Security-Policy", docsCSP())
		} else {
			h.Set("X-Frame-Options", "DENY")
			h.Set("Content-Security-Policy", "default-src 'none'")
		}
		next.ServeHTTP(w, r)
	})
}

// Recover turns panics into RFC-7807 problem responses (exception handling).
func Recover(log *slog.Logger) middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				if rec := recover(); rec != nil {
					log.Error("panic recovered", "err", rec, "path", r.URL.Path)
					writeJSON(w, http.StatusInternalServerError, map[string]any{
						"success": false,
						"error":   map[string]any{"type": "about:blank", "title": "internal error", "status": 500, "code": "dokandar.platform.internal.panic"},
					})
				}
			}()
			next.ServeHTTP(w, r)
		})
	}
}
