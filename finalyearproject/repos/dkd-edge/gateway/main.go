// api-gateway-svc — DOKANDAR edge #33 (SA §19.1: pure mediation — terminate, authenticate,
// shape, route; NO business logic, no store, no spine access). Pure Go stdlib.
//
// Enforced here (EF §7 / SA §19.3):
//   - Idempotency-Key PRESENCE on unsafe writes to money/custody-tier contexts (400 if
//     absent; dedup itself is owned by the target service's inbox — the gateway stores nothing)
//   - token-bucket rate limiting per client IP (numeric limits are canon NEEDS-INFO —
//     env policy data), 429 with mandatory Retry-After
//   - /internal/* seams are NEVER exposed through the edge
//   - problem+json normalization for gateway-level failures; envelopes pass through untouched
//
// AuthN posture: the JWT passes through to upstreams; AuthZ is the Identity PDP's job
// (deny-by-default server-side, ADR-008/G8) — and edge security is explicitly waived in
// this environment (fleet decision, BUILD-LOG).
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"
)

var (
	version   = "0.0.0-dev"
	gitSha    = "unknown"
	buildTime = "unknown"
)

type route struct {
	prefix         string
	upstream       string
	requireIdemKey bool // money/custody-tier unsafe writes need Idempotency-Key at the edge
}

func routesFromEnv() []route {
	base := getenv("DKD_UPSTREAM_BASE", "http://172.17.0.1")
	u := func(port string) string { return base + ":" + port }
	return []route{
		{"/v1/app/", u("8118"), false},
		{"/v1/parties", u("8080"), false},
		{"/v1/identity/", u("8080"), false},
		{"/v1/catalog/", u("8088"), false},
		{"/v1/custody/", u("8092"), true},
		{"/v1/inventory/", u("8094"), true},
		{"/v1/provenance/", u("8096"), false},
		{"/v1/finance/", u("8100"), true},
		{"/v1/b2c/", u("8102"), true},
		{"/v1/logistics/", u("8104"), true},
		{"/v1/b2b/", u("8106"), true},
		{"/v1/fraud/", u("8108"), true},
		{"/v1/oversight/", u("8098"), false},
		{"/v1/interventions", u("8098"), true},
		{"/v1/analytics/", u("8110"), false},
		{"/v1/notifications", u("8114"), true},
	}
}

// ---- token bucket per client key ----

type bucket struct {
	tokens float64
	last   time.Time
}

type limiter struct {
	mu        sync.Mutex
	buckets   map[string]*bucket
	rate      float64
	burst     float64
	lastSweep time.Time
}

const limiterMaxIdle = 10 * time.Minute
const limiterSweepEvery = time.Minute

func newLimiter(ratePerMin, burst int) *limiter {
	return &limiter{buckets: map[string]*bucket{}, rate: float64(ratePerMin) / 60.0,
		burst: float64(burst), lastSweep: time.Now()}
}

func (l *limiter) allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	// amortized idle eviction (reviewer H-1): the key set must never grow unbounded
	if now.Sub(l.lastSweep) > limiterSweepEvery {
		for k, b := range l.buckets {
			if now.Sub(b.last) > limiterMaxIdle {
				delete(l.buckets, k)
			}
		}
		l.lastSweep = now
	}
	b, ok := l.buckets[key]
	if !ok {
		b = &bucket{tokens: l.burst, last: now}
		l.buckets[key] = b
	}
	b.tokens += now.Sub(b.last).Seconds() * l.rate
	if b.tokens > l.burst {
		b.tokens = l.burst
	}
	b.last = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

// retryAfterSeconds reflects the actual refill window (RFC 6585 — reviewer L-3).
func (l *limiter) retryAfterSeconds() string {
	secs := int(1.0/l.rate) + 1
	return fmt.Sprintf("%d", secs)
}

// ---- handler ----

func buildHandler(log *slog.Logger, routes []route, lim *limiter) http.Handler {
	proxies := make(map[string]http.Handler, len(routes))
	for _, rt := range routes {
		target, err := url.Parse(rt.upstream)
		if err != nil {
			log.Error("bad upstream", "route", rt.prefix, "err", err)
			os.Exit(1)
		}
		p := httputil.NewSingleHostReverseProxy(target)
		orig := p.Director
		p.Director = func(req *http.Request) {
			req.Header.Del("X-Forwarded-For") // never trust an inbound chain (reviewer M-1)
			orig(req)
		}
		p.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
			log.Warn("upstream unavailable", "path", r.URL.Path, "err", err)
			problem(w, http.StatusServiceUnavailable,
				"dokandar.edge.infrastructure.upstream_unavailable",
				"upstream unavailable", "the context service did not answer", nil)
		}
		proxies[rt.prefix] = p
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "service": "api-gateway-svc",
			"version": version, "gitSha": gitSha})
	})
	mux.HandleFunc("/live", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"status": "ok"})
	})
	mux.HandleFunc("/ready", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"success": true,
			"data": map[string]any{"status": "ready", "routes": len(routes)}, "error": nil})
	})
	mux.HandleFunc("/version", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"success": true, "data": map[string]any{
			"version": version, "gitSha": gitSha, "buildTime": buildTime}, "error": nil})
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		if strings.Contains(r.URL.Path, "/internal/") || r.URL.Path == "/internal" {
			problem(w, http.StatusNotFound, "dokandar.edge.not_found.internal_seam",
				"not found", "internal seams are not exposed at the edge", nil)
			return
		}
		var matched *route
		for i := range routes {
			if matchesPrefix(r.URL.Path, routes[i].prefix) {
				matched = &routes[i]
				break
			}
		}
		if matched == nil {
			problem(w, http.StatusNotFound, "dokandar.edge.not_found.route",
				"not found", "no route for "+r.URL.Path, nil)
			return
		}
		if !lim.allow(clientKey(r)) {
			problem(w, http.StatusTooManyRequests, "dokandar.edge.rate.limited",
				"rate limited", "token bucket exhausted for this client",
				map[string]string{"Retry-After": lim.retryAfterSeconds()}) // EF 7.6.1
			return
		}
		if matched.requireIdemKey && isUnsafe(r.Method) && r.Header.Get("Idempotency-Key") == "" {
			problem(w, http.StatusBadRequest, "dokandar.edge.request.idempotency_key_required",
				"Idempotency-Key required",
				"unsafe writes to money/custody-tier contexts require Idempotency-Key (EF 7.4.1)",
				nil)
			return
		}
		proxies[matched.prefix].ServeHTTP(w, r)
		log.Info("proxied", "method", r.Method, "path", r.URL.Path,
			"upstream", matched.upstream, "elapsed_ms", time.Since(start).Milliseconds())
	})
	return mux
}

// matchesPrefix requires a path-segment boundary after non-slash prefixes
// ("/v1/parties" matches "/v1/parties" and "/v1/parties/…", never "/v1/partiesX").
func matchesPrefix(path, prefix string) bool {
	if !strings.HasPrefix(path, prefix) {
		return false
	}
	if strings.HasSuffix(prefix, "/") || len(path) == len(prefix) {
		return true
	}
	next := path[len(prefix)]
	return next == '/' || next == '?'
}

func clientKey(r *http.Request) string {
	ip := r.RemoteAddr
	if i := strings.LastIndex(ip, ":"); i > 0 {
		ip = ip[:i]
	}
	return ip
}

func isUnsafe(method string) bool {
	switch method {
	case http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete:
		return true
	}
	return false
}

func problem(w http.ResponseWriter, status int, code, title, detail string,
	headers map[string]string) {
	for k, v := range headers {
		w.Header().Set(k, v)
	}
	w.Header().Set("Content-Type", "application/problem+json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"type": "about:blank", "title": title, "status": status, "code": code, "detail": detail,
	})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func atoi(s string) int {
	n := 0
	_, _ = fmt.Sscanf(s, "%d", &n)
	if n <= 0 {
		n = 60
	}
	return n
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	port := getenv("DKD_HTTP_PORT", "8080")
	lim := newLimiter(atoi(getenv("DKD_RATE_PER_MIN", "300")), atoi(getenv("DKD_RATE_BURST", "60")))
	routes := routesFromEnv()
	// EDGE-03: install the real OTel tracer provider (record-only when DKD_OTLP_ENDPOINT unset).
	traceStop := initTracer(context.Background(), getenv("DKD_SERVICE_NAME", "api-gateway-svc"), getenv("DKD_OTLP_ENDPOINT", ""))
	srv := &http.Server{
		Addr: ":" + port, Handler: spanMiddleware(buildHandler(log, routes, lim)),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second,
		WriteTimeout: 60 * time.Second, IdleTimeout: 65 * time.Second,
	}
	go func() {
		log.Info("api-gateway-svc started", "port", port, "routes", len(routes))
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Error("listen", "err", err)
			os.Exit(1)
		}
	}()
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown incomplete", "err", err)
	}
	_ = traceStop(shutdownCtx) // EDGE-03: flush + stop the tracer provider
}
