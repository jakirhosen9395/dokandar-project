// Package proxy is the gateway's reverse-proxy core + the route table that wires
// every UPSTREAM_<SVC> behind a per-route auth-gate + rate-limit + verbatim
// forwarder, plus one concrete BFF aggregation endpoint. It is the layer that
// turns the foundation's stateless edge into an actual gateway.
//
// Seam with the foundation (cmd/gateway/main.go, FROZEN — do not change the
// call shape):
//
//	router := proxy.New(proxy.Config{Upstreams, ReadTimeout}, verifier, limiter)
//	e      := app.New(app.Deps{ …, Routes: router.Routes() })
//
// proxy.New takes the JWKS verifier and the Redis rate-limiter as the two narrow
// interfaces below (AuthVerifier / RateLimiter). The concrete *jwks.Verifier and
// *ratelimit.Limiter satisfy them STRUCTURALLY, so this package never imports
// internal/jwks or internal/ratelimit — it stays decoupled from those sibling
// agents and compiles against only internal/app, internal/config, internal/
// observability, echo, apm/v2 + stdlib. Router.Routes() returns []app.Route; the
// foundation's app.New registers each as [RateLimit, Auth] middleware around the
// handler (rate-limit outermost, so a shed request never costs a JWKS verify).
//
// Verbatim forwarding (architecture.md §5/§16): /api/v1/<svc>/… proxies UNCHANGED
// to UPSTREAM_<SVC> — the gateway never rewrites the path. Per-request deadline =
// Config.ReadTimeout; a transport/dial error → 502 upstream_error; a deadline →
// 504 upstream_timeout; an upstream that DID respond (incl. its own 5xx, already
// scrubbed by that service) streams back verbatim. gateway_upstream_errors_total
// {upstream} bumps on a transport failure or an upstream 5xx.
package proxy

import (
	"context"
	"errors"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/labstack/echo/v4"
	"go.elastic.co/apm/v2"

	"github.com/dokandar/dokandar-gateway/internal/app"
	"github.com/dokandar/dokandar-gateway/internal/observability"
)

// AuthVerifier is the narrow JWKS-verifier seam the proxy auth-gate calls. The
// concrete *jwks.Verifier (internal/jwks) satisfies it structurally:
//
//	func (v *Verifier) Verify(tokenString string) (jwt.MapClaims, error)
//
// — so this package does not import internal/jwks. The gate strips the "Bearer "
// prefix, calls Verify on the bare token, and stashes the claims as the request
// principal (which the rate-limiter's subject() can later key on, once a gate
// ordering exposes it).
type AuthVerifier interface {
	Verify(tokenString string) (jwt.MapClaims, error)
}

// RateLimiter is the narrow token-bucket seam the route table calls to derive a
// per-route gate. The concrete *ratelimit.Limiter (internal/ratelimit) satisfies
// it structurally:
//
//	func (l *Limiter) Limit(maxPerWindow, windowMS int, failOpen bool) echo.MiddlewareFunc
//
// A 0 for maxPerWindow/windowMS falls back to the limiter's constructed default
// budget; failOpen is the per-route degradation policy when Redis is down
// (storefront fail-open, sensitive fail-closed).
type RateLimiter interface {
	Limit(maxPerWindow, windowMS int, failOpen bool) echo.MiddlewareFunc
}

// Config is the proxy's runtime config (the subset of config.Settings main.go
// hands in). Upstreams is the {<svc-lower>: base-url} map config.Load() parsed
// from every UPSTREAM_<SVC>=… env var; ReadTimeout is the per-upstream deadline.
type Config struct {
	Upstreams   map[string]string
	ReadTimeout time.Duration
}

// Router holds the resolved config + the two gate factories. Build once in main
// via New, then call Routes() to get the []app.Route the foundation registers.
type Router struct {
	cfg     Config
	verify  AuthVerifier
	limiter RateLimiter

	// targets is the parsed {<svc>: *url.URL} form of cfg.Upstreams, built once
	// at construction (a bad URL is dropped with no route registered for it).
	targets map[string]*url.URL
}

// New builds the Router. It parses each upstream base URL once; an unparseable
// URL is skipped (no route registered) so a single typo can't break boot. The
// frozen main.go call is: proxy.New(proxy.Config{…}, verifier, limiter).
func New(cfg Config, verify AuthVerifier, limiter RateLimiter) *Router {
	targets := map[string]*url.URL{}
	for svc, base := range cfg.Upstreams {
		u, err := url.Parse(strings.TrimRight(base, "/"))
		if err != nil || u.Host == "" {
			continue
		}
		targets[svc] = u
	}
	return &Router{cfg: cfg, verify: verify, limiter: limiter, targets: targets}
}

// ---------------------------------------------------------------------------
// Reverse-proxy handler — verbatim path forwarding (architecture.md §5/§16).
// ---------------------------------------------------------------------------

// hopByHopHeaders are stripped before forwarding (RFC 7230 §6.1). net/http/
// httputil.ReverseProxy already removes these per the spec, but the BFF path
// uses a raw client, so the set is shared.
var hopByHopHeaders = []string{
	"Connection", "Proxy-Connection", "Keep-Alive", "Proxy-Authenticate",
	"Proxy-Authorization", "Te", "Trailer", "Transfer-Encoding", "Upgrade",
}

// svcLabelFor maps the lower-cased upstream key (e.g. "catalog") to the
// closed-set metric/label token "<NN>-<svc>" (e.g. "04-catalog") so the
// gateway_upstream_errors_total{upstream} label matches the spec + the /health
// upstream map. Falls back to the bare key for any service not in the table.
func svcLabelFor(svc string) string {
	if lbl, ok := svcLabels[svc]; ok {
		return lbl
	}
	return svc
}

// ProxyTo returns the verbatim reverse-proxy echo.HandlerFunc for one upstream.
// It forwards the request UNCHANGED (same path /api/v1/<svc>/…, method, body,
// headers minus hop-by-hop) to target, with a per-request deadline of
// r.cfg.ReadTimeout. svc is the lower-cased upstream key (for the metric label +
// the access-log UpstreamKey).
//
// Error mapping (architecture.md §5, reconciling "verbatim" with the §16 502/504
// contract): the upstream is wrapped in httputil.ReverseProxy whose ErrorHandler
// synthesizes the contract envelope ONLY when there is no upstream response —
// 504 upstream_timeout on a deadline (context.DeadlineExceeded), else 502
// upstream_error on a dial/transport failure. When the upstream DID respond
// (including its own 5xx, already scrubbed by that service) ModifyResponse lets
// it stream back verbatim and just bumps the metric on a 5xx. x-request-id is
// re-asserted on the way out so a copied upstream header can't clobber the
// gateway's id.
func (r *Router) ProxyTo(svc string, target *url.URL) echo.HandlerFunc {
	label := svcLabelFor(svc)

	rp := &httputil.ReverseProxy{
		// Director sets scheme/host from the upstream base and LEAVES the path
		// untouched (verbatim forwarding — no rewrite). It also preserves the
		// inbound Host as X-Forwarded-Host for the upstream's own logging.
		Director: func(req *http.Request) {
			req.URL.Scheme = target.Scheme
			req.URL.Host = target.Host
			req.Host = target.Host
			// Path is left exactly as received (/api/v1/<svc>/…). If the
			// upstream base itself carries a path prefix, honour it.
			if target.Path != "" && target.Path != "/" {
				req.URL.Path = singleJoiningSlash(target.Path, req.URL.Path)
			}
			// Strip hop-by-hop headers the inbound client may have set.
			for _, h := range hopByHopHeaders {
				req.Header.Del(h)
			}
		},

		// ModifyResponse runs when the upstream responded. Drop any x-request-id
		// the upstream echoed: the gateway's own id is already on the response
		// writer (set by the foundation's RequestID middleware) and remains
		// authoritative — without this Del, ReverseProxy's header copy APPENDS
		// the upstream's copy and yields a duplicate header. Then bump the error
		// metric on a 5xx (the body still streams back verbatim — the owning
		// service already scrubbed it).
		ModifyResponse: func(resp *http.Response) error {
			resp.Header.Del(echo.HeaderXRequestID)
			if resp.StatusCode >= 500 {
				observability.GatewayUpstreamErrorsTotal.
					WithLabelValues(observability.ServiceVal, label).Inc()
			}
			return nil
		},

		// ErrorHandler runs only when there is NO upstream response (dial /
		// transport / deadline). It writes the contract envelope + bumps the
		// metric. 504 on a deadline, 502 otherwise.
		ErrorHandler: func(w http.ResponseWriter, req *http.Request, err error) {
			observability.GatewayUpstreamErrorsTotal.
				WithLabelValues(observability.ServiceVal, label).Inc()
			status, code, msg := http.StatusBadGateway, "upstream_error", "upstream unavailable"
			if errors.Is(err, context.DeadlineExceeded) || isTimeout(err) {
				status, code, msg = http.StatusGatewayTimeout, "upstream_timeout", "upstream timed out"
			}
			writeEnvelope(w, req, status, code, msg)
		},
	}

	return func(c echo.Context) error {
		// Record the chosen upstream for the access log + RED route metric.
		c.Set(app.UpstreamKey, label)

		// Per-request deadline. The ReverseProxy honours the request context, so
		// a slow upstream trips ErrorHandler → 504 rather than hanging the edge.
		ctx, cancel := context.WithTimeout(c.Request().Context(), r.cfg.ReadTimeout)
		defer cancel()

		// One client span per upstream call, tagged with destination.service so it
		// appears as a DEPENDENCY (named by the upstream service, never raw IP:port)
		// and drives the service map. apm/v2 does NOT auto-instrument net/http, so the
		// destination metadata + the W3C traceparent are set explicitly here.
		span, sctx := apm.StartSpan(ctx, "proxy "+label, "external.http")
		if span != nil {
			span.Context.SetDestinationService(apm.DestinationServiceSpanContext{
				Name:     label, // dependency display name = the upstream service (e.g. 04-catalog)
				Resource: label, // the dependency node id in APM — never the raw IP:port
			})
			span.Context.SetServiceTarget(apm.ServiceTargetSpanContext{Type: "http", Name: label})
			defer span.End()
		}

		req := c.Request().WithContext(sctx)
		// Distributed tracing: propagate the W3C traceparent so the upstream service
		// CONTINUES this trace → the gateway→upstream service-map link forms automatically.
		if span != nil {
			tc := span.TraceContext()
			flags := "00"
			if tc.Options.Recorded() {
				flags = "01"
			}
			tp := "00-" + tc.Trace.String() + "-" + tc.Span.String() + "-" + flags
			req.Header.Set("traceparent", tp)
			req.Header.Set("elastic-apm-traceparent", tp) // legacy header for older agents
		}
		// Forward the canonical x-request-id downstream so the whole trace shares
		// it. The foundation's RequestID middleware stamps the id on the RESPONSE
		// header + context but never on the inbound request — when the gateway
		// MINTS an id (the common case; clients rarely send one), the upstream
		// would otherwise get no correlation id (architecture.md §11).
		if rid := app.RequestIDOf(c); rid != "" {
			req.Header.Set(echo.HeaderXRequestID, rid)
		}
		rp.ServeHTTP(c.Response(), req)
		return nil
	}
}

// ---------------------------------------------------------------------------
// Auth-gate — built HERE (the jwks.Verifier exposes only Verify, not an Echo
// middleware) so the proxy owns the Bearer extraction + the 401 envelope.
// ---------------------------------------------------------------------------

// principalKey is the echo.Context key under which the verified subject ("sub"
// claim) is stashed by the auth-gate, so a later layer (and the rate-limiter's
// subject() lookup) can key on the principal instead of the IP.
const principalKey = "principal"

// authGate returns the per-route Bearer gate: require an Authorization: Bearer
// header, Verify it (RS256-pinned, iss/aud/exp enforced inside the verifier),
// 401 token_invalid on any failure, else stash the principal and continue.
// Public routes pass nil for Auth and skip this entirely.
func (r *Router) authGate() echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			tok, ok := bearerToken(c.Request())
			if !ok {
				return app.ErrorEnvelope(c, http.StatusUnauthorized, "token_invalid",
					"missing or malformed Authorization Bearer token", nil)
			}
			claims, err := r.verify.Verify(tok)
			if err != nil {
				return app.ErrorEnvelope(c, http.StatusUnauthorized, "token_invalid",
					"invalid or expired token", nil)
			}
			if sub, _ := claims["sub"].(string); sub != "" {
				c.Set(principalKey, sub)
			}
			return next(c)
		}
	}
}

// bearerToken extracts the bare token from "Authorization: Bearer <tok>"
// (case-insensitive scheme). Returns ("", false) when absent/malformed.
func bearerToken(req *http.Request) (string, bool) {
	h := req.Header.Get(echo.HeaderAuthorization)
	const pfx = "bearer "
	if len(h) <= len(pfx) || !strings.EqualFold(h[:len(pfx)], pfx) {
		return "", false
	}
	tok := strings.TrimSpace(h[len(pfx):])
	if tok == "" {
		return "", false
	}
	return tok, true
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

// isTimeout reports whether err is a net timeout (i/o deadline exceeded) — the
// transport surfaces these as net.Error, not context.DeadlineExceeded, when the
// per-upstream read stalls mid-stream.
func isTimeout(err error) bool {
	var ne interface{ Timeout() bool }
	return errors.As(err, &ne) && ne.Timeout()
}

// singleJoiningSlash joins a base path prefix and the request path with exactly
// one slash (used only when an UPSTREAM_<SVC> base carries a path prefix).
func singleJoiningSlash(a, b string) string {
	as := strings.HasSuffix(a, "/")
	bs := strings.HasPrefix(b, "/")
	switch {
	case as && bs:
		return a + b[1:]
	case !as && !bs:
		return a + "/" + b
	}
	return a + b
}
