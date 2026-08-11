package app

import (
	"fmt"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/labstack/echo/v4"
	"go.elastic.co/apm/v2"

	"github.com/dokandar/dokandar-gateway/internal/observability"
)

// excludedFromAccessLog are the ops endpoints kept out of the structured access
// log (architecture.md §11/§16-j). They still flow through RED metrics? No —
// the access-log AND metrics both skip these high-frequency probe paths to keep
// the log + series cardinality clean. (RED still covers all business + ops JSON
// traffic; the three probes are noise.)
var excludedFromAccessLog = map[string]bool{
	"/ready":   true,
	"/metrics": true,
	"/health":  true,
}

// APM is the OUTERMOST middleware (registered first). There is no maintained
// apmecho build pinned to apm/v2 we can rely on without a `go mod tidy` we
// cannot run, so this is the manual equivalent (ported from 10-wallet's
// apmMiddleware): start an APM transaction, carry it on the request context so
// every downstream handler + log line nests under it and shares the trace id,
// then stamp the HTTP result and end it. The edge span is therefore the trace
// root. APM is diagnostic — an unconfigured tracer makes this a no-op and the
// request still flows.
func APM(tracer *apm.Tracer) echo.MiddlewareFunc {
	if tracer == nil {
		tracer = apm.DefaultTracer()
	}
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			tx := tracer.StartTransaction(c.Request().Method, "request")
			ctx := apm.ContextWithTransaction(c.Request().Context(), tx)
			c.SetRequest(c.Request().WithContext(ctx))

			err := next(c)

			// The matched route template is known only after routing ran.
			route := routePattern(c)
			tx.Name = c.Request().Method + " " + route
			status := c.Response().Status
			tx.Context.SetHTTPStatusCode(status)
			tx.Result = fmt.Sprintf("HTTP %dxx", status/100)
			tx.End()
			return err
		}
	}
}

// routePattern returns the matched route template (bounded cardinality, never a
// raw path with UUIDs). Falls back to "unmatched". Use c.Path() — Echo sets it
// to the registered pattern after routing.
func routePattern(c echo.Context) string {
	if p := c.Path(); p != "" {
		return p
	}
	return "unmatched"
}

// RequestID honours an inbound x-request-id or mints a uuid4, stashes it on the
// context (RequestIDKey) and echoes it on the response header. Registered right
// after APM so the id is available to every later layer + the error envelope.
func RequestID() echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			rid := strings.TrimSpace(c.Request().Header.Get(echo.HeaderXRequestID))
			if rid == "" {
				rid = uuid.NewString()
			}
			c.Set(RequestIDKey, rid)
			c.Response().Header().Set(echo.HeaderXRequestID, rid)
			return next(c)
		}
	}
}

// NewIPExtractor builds the echo.IPExtractor: CF-Connecting-IP wins (Cloudflare
// is the only thing in front of us), else the left-most UNtrusted entry of
// X-Forwarded-For, trusting only peers inside trustedCIDRs. A raw X-Forwarded-For
// is never trusted (architecture.md §11/§16-g). The result is what c.RealIP()
// returns; TrueClientIP also stashes it under TrueIPKey for the rate-limit key.
func NewIPExtractor(trustedCIDRs []string) echo.IPExtractor {
	ranges := parseCIDRs(trustedCIDRs)
	// Build the XFF extractor with the configured trusted ranges. Echo's
	// TrustIPRange takes one *net.IPNet per option, so fold the list in.
	opts := make([]echo.TrustOption, 0, len(ranges))
	for _, r := range ranges {
		opts = append(opts, echo.TrustIPRange(r))
	}
	xffExtract := echo.ExtractIPFromXFFHeader(opts...)

	return func(req *http.Request) string {
		if cf := strings.TrimSpace(req.Header.Get("CF-Connecting-IP")); cf != "" {
			if ip := net.ParseIP(cf); ip != nil {
				return cf
			}
		}
		return xffExtract(req)
	}
}

// TrueClientIP stashes c.RealIP() (already derived by the IPExtractor wired on
// the Echo instance) under TrueIPKey so the rate-limiter + access log read one
// canonical value. Register after the IPExtractor is set on the instance.
func TrueClientIP() echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			c.Set(TrueIPKey, c.RealIP())
			return next(c)
		}
	}
}

// SecurityAndCORS applies HSTS, CSP, X-Content-Type-Options: nosniff, and a
// CORS origin allowlist (NEVER '*' in stage/prod — architecture.md §12/§16-e).
// An empty allowlist means CORS headers are not emitted (no permissive '*').
// Preflight OPTIONS for an allowed origin short-circuits with 204.
func SecurityAndCORS(allowlist []string) echo.MiddlewareFunc {
	allowed := map[string]bool{}
	for _, o := range allowlist {
		allowed[strings.TrimRight(o, "/")] = true
	}
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			h := c.Response().Header()
			h.Set("Strict-Transport-Security", "max-age=63072000; includeSubDomains; preload")
			h.Set("X-Content-Type-Options", "nosniff")
			h.Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")

			origin := strings.TrimRight(c.Request().Header.Get(echo.HeaderOrigin), "/")
			if origin != "" && allowed[origin] {
				h.Set(echo.HeaderAccessControlAllowOrigin, origin)
				h.Set(echo.HeaderVary, echo.HeaderOrigin)
				h.Set(echo.HeaderAccessControlAllowCredentials, "true")
				h.Set(echo.HeaderAccessControlAllowMethods, "GET,POST,PUT,PATCH,DELETE,OPTIONS")
				h.Set(echo.HeaderAccessControlAllowHeaders, "Authorization,Content-Type,X-Request-Id,Idempotency-Key")
				if c.Request().Method == http.MethodOptions {
					return c.NoContent(http.StatusNoContent)
				}
			}
			return next(c)
		}
	}
}

// AccessLogAndMetrics is the after-response observability layer: it records RED
// (http_requests_total + http_request_duration_seconds, closed-set labels) and
// emits ONE structured access log line per request via slog — EXCLUDING /ready,
// /metrics, /health. The route label/log field is the templated c.Path(); the
// IP is the derived true client IP; the chosen upstream (if any) is included.
func AccessLogAndMetrics() echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			start := time.Now()
			err := next(c)
			// If a handler returned an error Echo has not yet committed the
			// HTTPErrorHandler; force it so the status is final before we read it.
			if err != nil {
				c.Error(err)
				err = nil
			}

			route := routePattern(c)
			method := c.Request().Method
			status := c.Response().Status
			latency := time.Since(start)

			observability.HTTPRequestsTotal.
				WithLabelValues(observability.ServiceVal, method, route, statusToken(status)).Inc()
			observability.HTTPRequestDuration.
				WithLabelValues(observability.ServiceVal, method, route).
				Observe(latency.Seconds())

			if excludedFromAccessLog[route] || excludedFromAccessLog[c.Request().URL.Path] {
				return err
			}

			upstream, _ := c.Get(UpstreamKey).(string)
			AccessLog(c, method, route, status, latency, upstream)
			return err
		}
	}
}

// statusToken collapses a status code to a closed-set RED token.
func statusToken(s int) string {
	switch {
	case s < 200:
		return "1xx"
	case s < 300:
		return "2xx"
	case s < 400:
		return "3xx"
	case s < 500:
		return "4xx"
	default:
		return "5xx"
	}
}

func parseCIDRs(cidrs []string) []*net.IPNet {
	out := make([]*net.IPNet, 0, len(cidrs))
	for _, c := range cidrs {
		c = strings.TrimSpace(c)
		if c == "" {
			continue
		}
		if !strings.Contains(c, "/") {
			// bare IP → /32 or /128
			if ip := net.ParseIP(c); ip != nil {
				if ip.To4() != nil {
					c += "/32"
				} else {
					c += "/128"
				}
			}
		}
		if _, n, err := net.ParseCIDR(c); err == nil {
			out = append(out, n)
		}
	}
	return out
}
