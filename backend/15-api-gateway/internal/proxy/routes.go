// routes.go builds the gateway's route table: for every UPSTREAM_<SVC> the proxy
// knows about, register /api/v1/<svc>/* behind the per-route auth-gate + rate-
// limit + verbatim forwarder, plus the BFF aggregation surface. Routes() returns
// the []app.Route the foundation's app.New registers (gates run [RateLimit, Auth]
// — rate-limit outermost). The route POLICY (public vs Bearer, the per-route
// budget, fail-open vs fail-closed) lives in the policies table below and is keyed
// by the lower-cased upstream <svc>; an upstream with no explicit policy defaults
// to Bearer-required + fail-closed + the global budget (the safe default for a
// service whose sensitivity we don't know).
package proxy

import (
	"encoding/json"
	"net/http"

	"github.com/labstack/echo/v4"

	"github.com/dokandar/dokandar-gateway/internal/app"
)

// svcLabels maps the lower-cased upstream env key (UPSTREAM_<SVC> → <svc>) to the
// closed-set "<NN>-<svc>" token used as the metric `upstream` label + the
// /health upstream map key. The full 18-service fleet (architecture.md fleet
// table / README §6) so every UPSTREAM_<SVC> resolves to a stable label.
var svcLabels = map[string]string{
	"support":        "00-support",
	"auth":           "01-auth",
	"profile":        "02-profile",
	"seller":         "03-seller",
	"catalog":        "04-catalog",
	"search":         "05-search",
	"cart":           "06-cart",
	"coupon":         "07-coupon",
	"review":         "08-review",
	"payment":        "09-payment",
	"wallet":         "10-wallet",
	"reporting":      "11-reporting",
	"media":          "12-media",
	"order":          "13-order",
	"notification":   "14-notification",
	"recommendation": "16-recommendation",
	"shipping":       "17-shipping",
	"risk":           "18-risk-trust",
}

// routePolicy is the per-route gate policy. requiresAuth toggles the Bearer gate;
// max/windowMS is the rate-limit budget (0 → the limiter's global default);
// failOpen is the Redis-down degradation policy (storefront fail-open, sensitive
// fail-closed).
type routePolicy struct {
	requiresAuth bool
	max          int // 0 → limiter default (RateLimitMax)
	windowMS     int // 0 → limiter default (RateLimitWindowMS)
	failOpen     bool
}

// policies is the per-service gate policy, keyed by the lower-cased <svc>
// (architecture.md §5). Storefront reads (auth/catalog/search) are public +
// fail-open so a Redis blip can't black out the storefront; per-user money/stock
// routes are Bearer + fail-closed. Notable budgets: search is chattier (60 anon /
// 120 — we apply a single 120/window since the gate runs before auth and can't
// distinguish anon vs user), payment is deliberately tight (20/window).
var policies = map[string]routePolicy{
	// --- public storefront reads (fail-open) ---
	"auth":    {requiresAuth: false, failOpen: true},                 // login/OTP/JWKS — public
	"catalog": {requiresAuth: false, failOpen: true},                 // product reads
	"search":  {requiresAuth: false, max: 120, windowMS: 1000, failOpen: true},
	"media":   {requiresAuth: false, failOpen: true},                 // presigned-asset reads
	// --- Bearer-required, per-user (fail-closed) ---
	"cart":           {requiresAuth: true, failOpen: false},
	"order":          {requiresAuth: true, failOpen: false},
	"wallet":         {requiresAuth: true, failOpen: false},
	"payment":        {requiresAuth: true, max: 20, windowMS: 1000, failOpen: false},
	"profile":        {requiresAuth: true, failOpen: false},
	"seller":         {requiresAuth: true, failOpen: false},
	"review":         {requiresAuth: true, failOpen: false},
	"coupon":         {requiresAuth: true, failOpen: false},
	"reporting":      {requiresAuth: true, failOpen: false},
	"recommendation": {requiresAuth: true, failOpen: false},
	"shipping":       {requiresAuth: true, failOpen: false},
	"risk":           {requiresAuth: true, failOpen: false},
	"notification":   {requiresAuth: true, failOpen: false},
	"support":        {requiresAuth: true, failOpen: false},
}

// proxyMethods is the closed set of HTTP methods each /api/v1/<svc>/* route is
// registered under. The foundation's app.New calls e.Add(r.Method, r.Path, …)
// once per app.Route, and Echo's Add registers a SINGLE method — "*" is not a
// real method and would only match a literal "*" request (every real GET/POST
// then falls through to the bare-404 catch-all). So we expand each proxied
// prefix across the concrete methods. c.Path() stays "/api/v1/<svc>/*" for all
// of them, so the rate-limit key + RED `route` label stay bounded; the `method`
// label distinguishes them.
var proxyMethods = []string{
	http.MethodGet, http.MethodHead, http.MethodPost,
	http.MethodPut, http.MethodPatch, http.MethodDelete, http.MethodOptions,
}

// defaultPolicy is applied to any upstream not in `policies` — safe default:
// Bearer-required, fail-closed, the global budget. (Covers a future UPSTREAM_<SVC>
// added to the env before this table is updated.)
var defaultPolicy = routePolicy{requiresAuth: true, failOpen: false}

// policyFor returns the route policy for the lower-cased upstream key.
func policyFor(svc string) routePolicy {
	if p, ok := policies[svc]; ok {
		return p
	}
	return defaultPolicy
}

// Routes builds the full route table the foundation registers. For each parsed
// upstream it adds ONE wildcard route /api/v1/<svc>/* (verbatim forwarding — the
// proxy never rewrites the path). The BFF aggregation route is appended last. The
// auth-gate is built here (the verifier exposes only Verify, not middleware); the
// rate-limit gate comes from the limiter's Limit(max,windowMS,failOpen) factory.
func (r *Router) Routes() []app.Route {
	out := make([]app.Route, 0, len(r.targets)+2)

	for svc, target := range r.targets {
		pol := policyFor(svc)

		// Build the gates + handler ONCE per service (not per method) so all
		// methods of a prefix share one auth-gate / rate-limiter / forwarder.
		var authMW echo.MiddlewareFunc
		if pol.requiresAuth {
			authMW = r.authGate()
		}
		rateMW := r.limiter.Limit(pol.max, pol.windowMS, pol.failOpen)
		handler := r.ProxyTo(svc, target)
		// Echo wildcard "/api/v1/<svc>/*" matches every sub-path under the
		// service prefix; the proxy forwards the full received path verbatim.
		path := "/api/v1/" + svc + "/*"

		for _, m := range proxyMethods {
			out = append(out, app.Route{
				Method:    m,
				Path:      path,
				Handler:   handler,
				Auth:      authMW,
				RateLimit: rateMW,
			})
		}
	}

	// BFF aggregation: GET /api/v1/bff/home (Bearer-required, fail-closed).
	out = append(out, app.Route{
		Method:    http.MethodGet,
		Path:      "/api/v1/bff/home",
		Handler:   r.BFFHome(),
		Auth:      r.authGate(),
		RateLimit: r.limiter.Limit(0, 0, false),
	})

	return out
}

// writeEnvelope writes the contract error envelope on a raw http.ResponseWriter
// (the ReverseProxy ErrorHandler has no echo.Context). Mirrors app.ErrorEnvelope:
// pretty-JSON (indent 2, ensure_ascii=false), {error:{code,message,request_id}},
// the request_id read back from the X-Request-Id header the foundation's
// RequestID middleware already stamped on the response.
func writeEnvelope(w http.ResponseWriter, req *http.Request, status int, code, message string) {
	rid := w.Header().Get(echo.HeaderXRequestID)
	if rid == "" {
		rid = req.Header.Get(echo.HeaderXRequestID)
	}
	body := map[string]any{
		"error": map[string]any{
			"code":       code,
			"message":    message,
			"request_id": rid,
		},
	}
	w.Header().Set(echo.HeaderContentType, "application/json; charset=utf-8")
	w.WriteHeader(status)
	e := json.NewEncoder(w)
	e.SetEscapeHTML(false)
	e.SetIndent("", "  ")
	_ = e.Encode(body)
}
