// Package app builds the Echo v4 instance: the cross-cutting middleware stack
// (APM outermost → request-id → recover → true-client-IP → security+CORS →
// access-log+RED), the five ops endpoints, then the rate-limit + auth-gate +
// reverse-proxy routes, and a bare-404 catch-all. The Foundation owns the
// wiring + the response/observability primitives; the four logic agents own the
// handler/middleware bodies and hand them in via Deps (the FIXED seam below).
//
// Echo version note: the spec says "Echo v5", but v5 is pre-GA and apmechov5
// does not exist, so this builds on github.com/labstack/echo/v4 — handlers are
// echo.HandlerFunc (func(echo.Context) error), gates are echo.MiddlewareFunc
// (func(echo.HandlerFunc) echo.HandlerFunc), the error handler is
// func(err error, c echo.Context), and the matched route template is c.Path().
package app

import (
	"errors"
	"net/http"

	"github.com/labstack/echo/v4"
	emw "github.com/labstack/echo/v4/middleware"
	"go.elastic.co/apm/v2"

	"github.com/dokandar/dokandar-gateway/internal/config"
)

// OpsHandlers is the seam the OPS agent fills (internal/ops). Each is a plain
// echo.HandlerFunc registered on the gateway's own root routes. Metrics/Docs/
// OpenAPI write raw (non-pretty) bodies; Ready/Health/Data use app.PrettyJSON.
type OpsHandlers struct {
	Ready   echo.HandlerFunc
	Health  echo.HandlerFunc
	Data    echo.HandlerFunc
	Metrics echo.HandlerFunc
	Docs    echo.HandlerFunc
	OpenAPI echo.HandlerFunc
}

// Route is one proxied/gateway route the PROXY agent declares. Method+Path are
// registered on Echo; Handler is the verbatim reverse-proxy (or a BFF handler);
// Auth/RateLimit are per-route gate middleware (nil = skip that gate). Gates run
// in the order [RateLimit, Auth] wrapped around Handler (rate-limit first so a
// shed request never costs a JWKS verify). Path uses Echo patterns, e.g.
// "/api/v1/catalog/*".
type Route struct {
	Method    string
	Path      string
	Handler   echo.HandlerFunc
	Auth      echo.MiddlewareFunc // nil → public
	RateLimit echo.MiddlewareFunc // nil → unlimited (ops-only routes)
}

// Deps is everything app.New needs. The Foundation provides Settings + Tracer;
// the logic agents provide Ops + Routes (built in main from their packages).
type Deps struct {
	Settings *config.Settings
	Tracer   *apm.Tracer
	Ops      OpsHandlers
	Routes   []Route
}

// New builds the configured Echo instance. Middleware order is load-bearing:
// APM is outermost so the edge span is the trace root.
func New(d Deps) *echo.Echo {
	e := echo.New()
	e.HideBanner = true
	e.HidePort = true

	// Derive the true client IP at the framework level (CF-Connecting-IP →
	// left-most untrusted XFF over the trusted-proxy allowlist). c.RealIP()
	// then returns this everywhere.
	e.IPExtractor = NewIPExtractor(d.Settings.TrustedProxyCIDRs)

	// Unmapped paths + method typos funnel to the contract bare-404 (Echo's
	// default 404/405 ship a JSON body — override).
	e.HTTPErrorHandler = HTTPErrorHandler

	tracer := d.Tracer
	if tracer == nil {
		tracer = apm.DefaultTracer()
	}

	// ---- cross-cutting middleware (outermost first) ----
	e.Use(APM(tracer))                                  // 1) trace root
	e.Use(RequestID())                                  // 2) honour-or-mint x-request-id
	e.Use(emw.Recover())                                // 3) panic → HTTPErrorHandler
	e.Use(TrueClientIP())                               // 4) stash derived IP
	e.Use(SecurityAndCORS(d.Settings.CORSAllowlist))    // 5) HSTS/CSP/nosniff + CORS
	e.Use(AccessLogAndMetrics())                        // 6) RED + access log (after-response)

	// ---- the five ops endpoints (public, no auth, no rate-limit) ----
	e.GET("/ready", d.Ops.Ready)
	e.GET("/health", d.Ops.Health)
	e.GET("/data", d.Ops.Data)
	e.GET("/metrics", d.Ops.Metrics)
	e.GET("/docs", d.Ops.Docs)
	e.GET("/openapi.json", d.Ops.OpenAPI)

	// ---- rate-limit + auth-gate + reverse-proxy routes ----
	for _, r := range d.Routes {
		h := r.Handler
		mws := make([]echo.MiddlewareFunc, 0, 2)
		if r.RateLimit != nil {
			mws = append(mws, r.RateLimit)
		}
		if r.Auth != nil {
			mws = append(mws, r.Auth)
		}
		e.Add(r.Method, r.Path, h, mws...)
	}

	// ---- bare-404 catch-all (any method, any unmapped path) ----
	e.Any("/*", func(c echo.Context) error { return Bare404(c) })

	return e
}

// HTTPErrorHandler renders the gateway's edge errors. echo.ErrNotFound /
// ErrMethodNotAllowed (unmapped path, method typo) become the contract bare-404.
// Everything else becomes the single error envelope; 5xx never leaks internals.
func HTTPErrorHandler(err error, c echo.Context) {
	if c.Response().Committed {
		return
	}

	var he *echo.HTTPError
	if errors.As(err, &he) {
		switch he.Code {
		case http.StatusNotFound, http.StatusMethodNotAllowed:
			_ = Bare404(c)
			return
		}
		code := he.Code
		msg := http.StatusText(code)
		machine := machineCode(code)
		if m, ok := he.Message.(string); ok && m != "" {
			msg = m
		}
		if code >= 500 {
			msg = "internal error"
			machine = "internal_error"
		}
		_ = ErrorEnvelope(c, code, machine, msg, nil)
		return
	}

	// Non-HTTPError → 500, scrubbed.
	_ = ErrorEnvelope(c, http.StatusInternalServerError, "internal_error", "internal error", nil)
}

// machineCode maps a status to a stable machine token used in the error envelope.
func machineCode(code int) string {
	switch code {
	case http.StatusUnauthorized:
		return "token_invalid"
	case http.StatusForbidden:
		return "forbidden"
	case http.StatusTooManyRequests:
		return "rate_limited"
	case http.StatusBadGateway:
		return "upstream_error"
	case http.StatusGatewayTimeout:
		return "upstream_timeout"
	case http.StatusBadRequest:
		return "bad_request"
	default:
		if code >= 500 {
			return "internal_error"
		}
		return "error"
	}
}
