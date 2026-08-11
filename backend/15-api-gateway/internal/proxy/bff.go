// bff.go is the gateway's ONE concrete BFF (Backend-For-Frontend) aggregation
// endpoint: GET /api/v1/bff/home. It fans out to several upstreams concurrently,
// stitches their JSON into one {sections:{…}} envelope for a composite home
// screen, and DEGRADES a failed section to null rather than failing the whole
// response (architecture.md §1/§5/§13). This documents the BFF pattern; the full
// catalog of BFF screens is an open item (§17).
//
// Why a separate path from ProxyTo: the reverse-proxy forwards ONE request
// verbatim; a BFF fans out to many and reshapes the result. So the BFF uses a
// plain http.Client round-trip per section (not the ReverseProxy), forwards the
// caller's Authorization header to each upstream (the Bearer gate already
// verified it), and bounds each section by the same per-upstream ReadTimeout. A
// section whose upstream is missing/erroring/timing-out becomes `null`.
package proxy

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"sync"

	"github.com/labstack/echo/v4"

	"github.com/dokandar/dokandar-gateway/internal/app"
)

// bffSection declares one fan-out: the upstream <svc> key + the sub-path to GET
// on it. The stitched response keys each result under `name`. A section whose
// upstream is not configured, or that errors/times-out, degrades to null.
type bffSection struct {
	name string // key in sections{}
	svc  string // lower-cased upstream key (must be in r.targets)
	path string // path to GET on that upstream (verbatim, incl. /api/v1/…)
}

// homeSections is the home screen's fan-out plan: featured catalog + the user's
// recommendation feed + the user's cart. Each is an independent section.
var homeSections = []bffSection{
	{name: "featured", svc: "catalog", path: "/api/v1/catalog/products?featured=true&limit=20"},
	{name: "recommendations", svc: "recommendation", path: "/api/v1/recommendation/feed/me"},
	{name: "cart", svc: "cart", path: "/api/v1/cart/me"},
}

// bffClient is the shared round-trip client for BFF fan-out (separate from the
// ReverseProxy). Per-section deadline is applied via context, not this timeout,
// so the cap is uniform with the proxy's ReadTimeout.
var bffClient = &http.Client{Timeout: 0}

// BFFHome returns the GET /api/v1/bff/home handler. Bearer-required (wired in
// Routes with r.authGate()). It fans out to homeSections concurrently, each
// bounded by r.cfg.ReadTimeout, and stitches {sections:{<name>:<json>|null}}.
// A failed/missing/timed-out section is null — the response itself is always 200
// with the error envelope reserved for the BFF route's OWN failure (never a
// section's).
func (r *Router) BFFHome() echo.HandlerFunc {
	return func(c echo.Context) error {
		// This is a gateway-owned aggregation, not a single proxied upstream —
		// label it so the access log + RED route metric attribute it to the BFF.
		c.Set(app.UpstreamKey, "bff")

		authz := c.Request().Header.Get(echo.HeaderAuthorization)
		reqID := app.RequestIDOf(c)

		sections := make(map[string]json.RawMessage, len(homeSections))
		var mu sync.Mutex
		var wg sync.WaitGroup

		for _, sec := range homeSections {
			target, ok := r.targets[sec.svc]
			if !ok {
				// Upstream not configured → section degrades to null.
				mu.Lock()
				sections[sec.name] = nil
				mu.Unlock()
				continue
			}
			wg.Add(1)
			go func(sec bffSection, base string) {
				defer wg.Done()
				raw := r.fetchSection(c.Request().Context(), base+sec.path, authz, reqID)
				mu.Lock()
				sections[sec.name] = raw // raw is nil on any failure
				mu.Unlock()
			}(sec, target.String())
		}
		wg.Wait()

		// json.RawMessage(nil) marshals as `null`, so a degraded section is null.
		return app.PrettyJSON(c, http.StatusOK, map[string]any{"sections": sections})
	}
}

// fetchSection GETs one upstream URL with the caller's Authorization + the
// gateway's x-request-id, bounded by ReadTimeout. Returns the raw JSON body on a
// 2xx, or nil (→ the section degrades to null) on any error: bad request, dial /
// timeout, non-2xx status, unreadable or non-JSON body. A degraded section never
// fails the whole BFF response.
func (r *Router) fetchSection(parent context.Context, url, authz, reqID string) json.RawMessage {
	ctx, cancel := context.WithTimeout(parent, r.cfg.ReadTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil
	}
	req.Header.Set("Accept", "application/json")
	if authz != "" {
		req.Header.Set(echo.HeaderAuthorization, authz)
	}
	if reqID != "" {
		req.Header.Set(echo.HeaderXRequestID, reqID)
	}

	resp, err := bffClient.Do(req)
	if err != nil {
		return nil // dial / timeout → degrade
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil // upstream error → degrade
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20)) // 4 MiB ceiling
	if err != nil || len(body) == 0 {
		return nil
	}
	if !json.Valid(body) {
		return nil // non-JSON body → degrade (we stitch into a JSON envelope)
	}
	return json.RawMessage(body)
}
