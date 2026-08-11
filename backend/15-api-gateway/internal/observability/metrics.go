// Prometheus counters/histograms for the api-gateway. Hand-rolled registry,
// closed-set labels only — keeps cardinality bounded (route/upstream/result are
// templated tokens; the client IP and principal are NEVER labels).
//
// The gateway is stateless and emits no events, so there is NO *_outbox_pending
// gauge here (architecture.md §10). The metric names + labels are part of the
// acceptance contract — do not rename without updating smoke_test/test.sh.
package observability

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// ServiceVal is the closed-set `service` label value on every series. Must
// equal SERVICE_NAME (= "15-api-gateway").
const ServiceVal = "15-api-gateway"

var (
	// RED — HTTP request counter. status is a closed-set token (2xx/4xx/5xx),
	// route is the matched route pattern (c.Path(); never a raw path / UUID).
	HTTPRequestsTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "http_requests_total",
		Help: "HTTP requests served, by method + route + status.",
	}, []string{"service", "method", "route", "status"})

	HTTPRequestDuration = prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "HTTP request duration histogram.",
		Buckets: prometheus.DefBuckets,
	}, []string{"service", "method", "route"})

	// Edge-domain counters.

	// GatewayRateLimitedTotal — requests shed by the Redis token bucket, by route.
	GatewayRateLimitedTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "gateway_rate_limited_total",
		Help: "Requests rejected by the rate-limiter (429), by route.",
	}, []string{"service", "route"})

	// GatewayUpstreamErrorsTotal — proxy failures (502/504), by upstream service.
	GatewayUpstreamErrorsTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "gateway_upstream_errors_total",
		Help: "Reverse-proxy failures (timeout / unreachable / 5xx), by upstream.",
	}, []string{"service", "upstream"})

	// GatewayJWKSRefreshTotal — JWKS cache refresh outcomes (result=ok|error).
	GatewayJWKSRefreshTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "gateway_jwks_refresh_total",
		Help: "JWKS cache refresh attempts against 01-auth, by result.",
	}, []string{"service", "result"})
)

func init() {
	prometheus.MustRegister(
		HTTPRequestsTotal,
		HTTPRequestDuration,
		GatewayRateLimitedTotal,
		GatewayUpstreamErrorsTotal,
		GatewayJWKSRefreshTotal,
	)
	// Pre-create the zero series so each metric's HELP/TYPE + a series line
	// appears in /metrics from boot — client_golang omits a Vec entirely until
	// a label combination is observed once, and the smoke greps the names
	// before any real traffic. (http_requests_total is left alone — real
	// traffic populates it with a real route label; a placeholder would inject
	// a bogus series.)
	GatewayJWKSRefreshTotal.WithLabelValues(ServiceVal, "ok")
	GatewayJWKSRefreshTotal.WithLabelValues(ServiceVal, "error")
}

// MetricsHandler returns the standard promhttp handler — wired at /metrics.
func MetricsHandler() http.Handler { return promhttp.Handler() }
