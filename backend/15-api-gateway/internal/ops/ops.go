// Package ops implements the gateway's own five operational endpoints (the
// contract surface every DOKANDAR service shares) on top of Echo v4. It is the
// stateless edge, so the shapes differ from a stateful service in two
// load-bearing ways (architecture.md §8 / §16):
//
//   - GET /ready gates on NOTHING external — dependencies:[] always. A Redis or
//     upstream blip must never pull the single front door out of the LB
//     (§8.1/§16-a). It is 200 once the process is listening.
//   - GET /health TCP-probes each upstream for *reachability* (net.DialTimeout),
//     NOT the upstreams' /ready — that would couple the edge's health to every
//     downstream's readiness (§8.2/§16-b). Nothing in /health flips status; it
//     is always 200 (diagnostic only).
//
// The handlers are plain echo.HandlerFunc values handed to the Foundation's
// app.New via Handlers() → app.OpsHandlers. Ready/Health/Data use the
// Foundation's app.PrettyJSON (pretty-JSON contract); Metrics/Docs/OpenAPI write
// raw bodies (metrics is Prometheus text; docs/openapi are not pretty-indented).
package ops

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/labstack/echo/v4"
	"github.com/redis/go-redis/v9"

	"github.com/dokandar/dokandar-gateway/internal/app"
	"github.com/dokandar/dokandar-gateway/internal/config"
	"github.com/dokandar/dokandar-gateway/internal/observability"
)

// jwksHealther is the optional health surface the JWKS verifier may expose.
// ops is decoupled from the jwks package (a sibling agent owns it): if the
// verifier handed in via Deps.JWKS implements this, /health reports its real
// state; otherwise /health reports the safe default {ok:true, detail:"cached"}
// (the verifier always serves from its 5-min in-process cache, so a JWKS fetch
// blip is not an outage). Keeping this an interface — not an import — means ops
// compiles and ships regardless of the verifier's concrete type.
type jwksHealther interface {
	JWKSHealth() (ok bool, detail string)
}

// Deps is everything the ops handlers need. Wired in cmd/gateway/main.go. The
// JWKS field is `any` on purpose (see jwksHealther) so this package does not
// import internal/jwks.
type Deps struct {
	Settings  *config.Settings
	Code      string
	BootTime  time.Time
	DataDir   string // "data" (cwd) — also probed at /app/data for the container
	Redis     *redis.Client
	JWKS      any
	Logs      *observability.LogSinks
	Upstreams map[string]string // {<svc-lower>: base-url}
}

// Handler holds the resolved dependencies for the five ops endpoints.
type Handler struct{ d Deps }

// New builds the ops Handler.
func New(d Deps) *Handler { return &Handler{d: d} }

// Handlers returns the seam the Foundation's app.New consumes: each field is a
// plain echo.HandlerFunc registered on a gateway-owned root route.
func (h *Handler) Handlers() app.OpsHandlers {
	return app.OpsHandlers{
		Ready:   h.Ready,
		Health:  h.Health,
		Data:    h.Data,
		Metrics: h.Metrics,
		Docs:    h.Docs,
		OpenAPI: h.OpenAPI,
	}
}

// ---------------------------------------------------------------------------
// Identity block — shared by /ready /health /data /docs (the OpenAPI banner).
// ---------------------------------------------------------------------------

// Identity is the platform-standard service-fingerprint block. Field order is
// part of the contract: name → versions → env shape → uptime.
type Identity struct {
	ServiceName   string `json:"service_name"`
	CodeVersion   string `json:"code_version"`
	EnvVersion    string `json:"env_version"`
	Tenant        string `json:"tenant"`
	Env           string `json:"env"`
	UptimeSeconds int    `json:"uptime_seconds"`
}

func (h *Handler) identity() Identity {
	return Identity{
		ServiceName:   h.d.Settings.ServiceName,
		CodeVersion:   h.d.Code,
		EnvVersion:    h.d.Settings.EnvVersion,
		Tenant:        h.d.Settings.Tenant,
		Env:           h.d.Settings.AppEnv,
		UptimeSeconds: int(time.Since(h.d.BootTime).Seconds()),
	}
}

// ---------------------------------------------------------------------------
// GET /ready — gates on NOTHING external (§8.1/§16-a).
// ---------------------------------------------------------------------------

// ReadyBody — note dependencies is ALWAYS an empty (non-nil) slice: the edge
// lists no traffic-gating deps. JSON renders `[]`, never `null`.
type ReadyBody struct {
	Status       string   `json:"status"`
	Identity     Identity `json:"identity"`
	Dependencies []string `json:"dependencies"`
}

// Ready returns 200 the moment the process is listening. No Redis/upstream/JWKS
// check participates — a downstream outage degrades a behaviour, never readiness.
func (h *Handler) Ready(c echo.Context) error {
	return app.PrettyJSON(c, http.StatusOK, ReadyBody{
		Status:       "ready",
		Identity:     h.identity(),
		Dependencies: []string{}, // EMPTY — the front door gates on nothing (§8.1)
	})
}

// ---------------------------------------------------------------------------
// GET /health — diagnostic; TCP-probes upstreams; never flips status (§8.2).
// ---------------------------------------------------------------------------

// Check is one entry under /health.checks{}.
type Check struct {
	OK     bool   `json:"ok"`
	Detail string `json:"detail,omitempty"`
}

// HealthObservability is the observability block — the three join keys an SRE
// uses to find this service's traces (APM) + logs (Mongo + ES).
type HealthObservability struct {
	APMServiceName string `json:"apm_service_name"`
	APMServerURL   string `json:"apm_server_url,omitempty"`
	LogsSinkMongo  string `json:"logs_sink_mongo"`
	LogsSinkES     string `json:"logs_sink_es"`
}

// HealthBody — field order: status → identity → checks → upstreams → observability.
type HealthBody struct {
	Status        string              `json:"status"`
	Identity      Identity            `json:"identity"`
	Checks        map[string]Check    `json:"checks"`
	Upstreams     map[string]Check    `json:"upstreams"`
	Observability HealthObservability `json:"observability"`
}

// Health is ALWAYS 200 (diagnostic). It reports redis + jwks + apm in `checks`,
// the per-upstream TCP-reachability in `upstreams`, and the observability join
// keys. NONE of these flip the status — the edge stays "healthy" regardless, so
// a single down upstream never marks the front door unhealthy (§8.2/§16-b).
func (h *Handler) Health(c echo.Context) error {
	ctx := c.Request().Context()

	checks := map[string]Check{
		"redis": h.redisCheck(ctx),
		"jwks":  h.jwksCheck(),
		"apm":   h.apmCheck(),
	}
	upstreams := h.probeUpstreams(ctx)

	return app.PrettyJSON(c, http.StatusOK, HealthBody{
		Status:    "healthy", // diagnostic — never flips (§8.2)
		Identity:  h.identity(),
		Checks:    checks,
		Upstreams: upstreams,
		Observability: HealthObservability{
			APMServiceName: h.d.Settings.APMServiceName,
			APMServerURL:   h.d.Settings.APMServerURL,
			LogsSinkMongo:  h.mongoSinkDisplay(),
			LogsSinkES:     h.esSinkDisplay(),
		},
	})
}

// redisCheck pings Redis DB 13 (the rate-limiter store). Diagnostic only — a
// Redis outage degrades the rate-limit policy, it does not unready the edge.
func (h *Handler) redisCheck(ctx context.Context) Check {
	if h.d.Redis == nil {
		return Check{OK: false, Detail: "not_configured"}
	}
	c, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()
	if err := h.d.Redis.Ping(c).Err(); err != nil {
		return Check{OK: false, Detail: "unreachable"}
	}
	return Check{OK: true, Detail: "db13"}
}

// jwksCheck reports the verifier's health if it exposes one, else the safe
// default {ok:true, detail:"cached"} — verification always runs off the in-proc
// cache, so a fetch blip is not an outage (architecture.md §8.2/§13).
func (h *Handler) jwksCheck() Check {
	if hv, ok := h.d.JWKS.(jwksHealther); ok {
		healthy, detail := hv.JWKSHealth()
		if detail == "" {
			detail = "cached"
		}
		return Check{OK: healthy, Detail: detail}
	}
	return Check{OK: true, Detail: "cached"}
}

// apmCheck TCP-probes the APM server (diagnostic). No APM_SERVER_URL → not
// configured; this never flips status.
func (h *Handler) apmCheck() Check {
	if h.d.Settings.APMServerURL == "" {
		return Check{OK: false, Detail: "not_configured"}
	}
	ok, detail := observability.APMServerReachable(h.d.Settings.APMServerURL, 1500*time.Millisecond)
	return Check{OK: ok, Detail: detail}
}

// probeUpstreams TCP-DialTimeouts the host:port of each UPSTREAM_<svc> target
// concurrently. This is REACHABILITY only — it never calls the upstream's
// /ready (§8.2/§16-b). Keyed by the same lower-cased <svc> the proxy uses.
func (h *Handler) probeUpstreams(ctx context.Context) map[string]Check {
	out := map[string]Check{}
	if len(h.d.Upstreams) == 0 {
		return out
	}
	var mu sync.Mutex
	var wg sync.WaitGroup
	for svc, raw := range h.d.Upstreams {
		wg.Add(1)
		go func(svc, raw string) {
			defer wg.Done()
			chk := tcpProbe(raw, 1200*time.Millisecond)
			mu.Lock()
			out[svc] = chk
			mu.Unlock()
		}(svc, raw)
	}
	wg.Wait()
	return out
}

// tcpProbe resolves the host:port of an upstream base URL and dials it.
func tcpProbe(rawURL string, timeout time.Duration) Check {
	u, err := url.Parse(rawURL)
	if err != nil || u.Host == "" {
		return Check{OK: false, Detail: "bad_url"}
	}
	port := u.Port()
	if port == "" {
		if u.Scheme == "https" {
			port = "443"
		} else {
			port = "80"
		}
	}
	addr := net.JoinHostPort(u.Hostname(), port)
	conn, err := net.DialTimeout("tcp", addr, timeout)
	if err != nil {
		return Check{OK: false, Detail: "unreachable"}
	}
	_ = conn.Close()
	return Check{OK: true, Detail: addr}
}

func (h *Handler) mongoSinkDisplay() string {
	if h.d.Settings.MongoLogURI == "" {
		return "disabled"
	}
	return fmt.Sprintf("mongodb://%s/%s", h.d.Settings.MongoLogDB, h.d.Settings.ServiceName)
}

func (h *Handler) esSinkDisplay() string {
	if h.d.Settings.ElasticSearchURL == "" {
		return "disabled"
	}
	return fmt.Sprintf("%s/logs-app-%s-*", h.d.Settings.ElasticSearchURL, h.d.Settings.ServiceName)
}

// ---------------------------------------------------------------------------
// GET /data — TENANT snapshot (identity prepended); contract error codes.
// ---------------------------------------------------------------------------

// Data serves data/<TENANT>/result.json (bind-mounted RO) with the identity
// block prepended. 404 no_snapshot when the file is absent; 500
// snapshot_parse_failed when it is not a JSON object (contract §8.3).
func (h *Handler) Data(c echo.Context) error {
	tenant := h.d.Settings.Tenant
	if tenant == "" {
		tenant = "local"
	}
	// Try ./data (native cwd) then /app/data (the container bind-mount).
	candidates := []string{
		filepath.Join(h.d.DataDir, tenant, "result.json"),
		filepath.Join("/app", "data", tenant, "result.json"),
	}
	var raw []byte
	found := false
	for _, p := range candidates {
		if b, err := os.ReadFile(p); err == nil {
			raw, found = b, true
			break
		}
	}
	if !found {
		return app.ErrorEnvelope(c, http.StatusNotFound, "no_snapshot",
			fmt.Sprintf("no data snapshot for tenant %q (run data/%s/collect.sh)", tenant, tenant), nil)
	}

	var snapshot map[string]any
	if err := json.Unmarshal(raw, &snapshot); err != nil {
		return app.ErrorEnvelope(c, http.StatusInternalServerError, "snapshot_parse_failed",
			"data snapshot is not a JSON object", nil)
	}

	// identity block first, then the snapshot fields.
	body := map[string]any{"identity": h.identity()}
	for k, v := range snapshot {
		if k == "identity" {
			continue
		}
		body[k] = v
	}
	return app.PrettyJSON(c, http.StatusOK, body)
}

// ---------------------------------------------------------------------------
// GET /metrics — Prometheus text exposition (the one non-pretty-JSON endpoint).
// ---------------------------------------------------------------------------

// Metrics serves the promhttp handler. Excluded from the access log by the
// Foundation's AccessLogAndMetrics middleware.
func (h *Handler) Metrics(c echo.Context) error {
	observability.MetricsHandler().ServeHTTP(c.Response(), c.Request())
	return nil
}

// ---------------------------------------------------------------------------
// GET /openapi.json + GET /docs — hand-written OpenAPI of the gateway's OWN
// routes (the proxied upstream APIs are documented by their owners, §6).
// ---------------------------------------------------------------------------

// OpenAPI serves the hand-written gateway OpenAPI document (raw JSON, not
// pretty-indented — it is consumed by Swagger UI, not read by a human).
func (h *Handler) OpenAPI(c echo.Context) error {
	doc := h.openAPIDoc()
	b, err := json.Marshal(doc)
	if err != nil {
		return app.ErrorEnvelope(c, http.StatusInternalServerError, "internal_error", "internal error", nil)
	}
	return c.Blob(http.StatusOK, "application/json; charset=utf-8", b)
}

// openAPIDoc builds the gateway's hand-written OpenAPI 3.0.3 document: the five
// ops endpoints + the BFF aggregation prefix + the standard error envelope +
// the gateway's edge error codes (401/403/429/502/504) + the HTTPBearer scheme.
func (h *Handler) openAPIDoc() map[string]any {
	id := h.identity()
	desc := fmt.Sprintf(
		"**service_name**: `%s` &nbsp;|&nbsp; **code_version**: `%s` &nbsp;|&nbsp; "+
			"**env_version**: `%s` &nbsp;|&nbsp; **tenant**: `%s` &nbsp;|&nbsp; **env**: `%s`\n\n"+
			"### What this documents\n"+
			"The **gateway's own** routes only — the five ops endpoints and the `/api/v1/bff/*` "+
			"aggregation surface. The proxied upstream APIs (`/api/v1/<svc>/*`) are documented by "+
			"their owning services; the gateway forwards those paths **verbatim**.\n\n"+
			"### How to get & use a token\n"+
			"1. `POST /api/v1/auth/login/request` then `/api/v1/auth/login/verify` against the "+
			"gateway to obtain a Bearer **access token** (RS256).\n"+
			"2. Click **Authorize**, paste the token. Bearer-required routes "+
			"(`/api/v1/cart|order|wallet|payment/*`, `/api/v1/bff/*`) then carry it; the gateway "+
			"verifies it against `01-auth`'s JWKS (5-min cache, `algorithms:['RS256']` pinned).\n\n"+
			"### Edge error codes\n"+
			"`401 token_invalid` · `403 forbidden` · `429 rate_limited` · `502 upstream_error` · "+
			"`504 upstream_timeout` — all in the standard error envelope.",
		id.ServiceName, id.CodeVersion, id.EnvVersion, id.Tenant, id.Env,
	)

	// Standard responses (referenced from each path).
	errEnvelopeSchema := map[string]any{
		"type": "object", "required": []string{"error"},
		"properties": map[string]any{
			"error": map[string]any{
				"type": "object", "required": []string{"code", "message", "request_id"},
				"properties": map[string]any{
					"code":       map[string]any{"type": "string", "example": "rate_limited"},
					"message":    map[string]any{"type": "string"},
					"request_id": map[string]any{"type": "string"},
					"details":    map[string]any{"type": "object", "nullable": true},
				},
			},
		},
	}
	identitySchema := map[string]any{
		"type": "object",
		"properties": map[string]any{
			"service_name":   map[string]any{"type": "string", "example": id.ServiceName},
			"code_version":   map[string]any{"type": "string", "example": id.CodeVersion},
			"env_version":    map[string]any{"type": "string", "example": id.EnvVersion},
			"tenant":         map[string]any{"type": "string", "example": id.Tenant},
			"env":            map[string]any{"type": "string", "example": id.Env},
			"uptime_seconds": map[string]any{"type": "integer", "example": 42},
		},
	}

	errRef := func(desc string) map[string]any {
		return map[string]any{
			"description": desc,
			"content": map[string]any{
				"application/json": map[string]any{
					"schema": map[string]any{"$ref": "#/components/schemas/ErrorEnvelope"},
				},
			},
		}
	}
	jsonResp := func(desc, schemaRef string) map[string]any {
		content := map[string]any{}
		if schemaRef != "" {
			content["application/json"] = map[string]any{
				"schema": map[string]any{"$ref": schemaRef},
			}
		}
		r := map[string]any{"description": desc}
		if len(content) > 0 {
			r["content"] = content
		}
		return r
	}

	paths := map[string]any{
		"/ready": map[string]any{
			"get": map[string]any{
				"operationId": "opsReady",
				"tags":        []string{"ops"}, "summary": "Readiness — gates on nothing external",
				"description": "200 once the process is listening. `dependencies` is **always empty** — " +
					"the single front door must never be pulled from the LB by a downstream blip (§8.1).",
				"responses": map[string]any{
					"200": jsonResp("Ready (always, once up).", "#/components/schemas/ReadyBody"),
				},
			},
		},
		"/health": map[string]any{
			"get": map[string]any{
				"operationId": "opsHealth",
				"tags":        []string{"ops"}, "summary": "Diagnostics — TCP-probes upstreams; never flips status",
				"description": "Always 200. Reports redis/jwks/apm `checks` + per-upstream TCP-reachability " +
					"`upstreams` + the observability join keys. None of these flip readiness (§8.2).",
				"responses": map[string]any{
					"200": jsonResp("Diagnostic snapshot.", "#/components/schemas/HealthBody"),
				},
			},
		},
		"/data": map[string]any{
			"get": map[string]any{
				"operationId": "opsData",
				"tags":        []string{"ops"}, "summary": "TENANT host snapshot (identity prepended)",
				"responses": map[string]any{
					"200": jsonResp("The data/<tenant>/result.json snapshot with identity prepended.", ""),
					"404": errRef("`no_snapshot` — no snapshot rendered for this tenant."),
					"500": errRef("`snapshot_parse_failed` — snapshot is not a JSON object."),
				},
			},
		},
		"/metrics": map[string]any{
			"get": map[string]any{
				"operationId": "opsMetrics",
				"tags":        []string{"ops"}, "summary": "Prometheus exposition (text)",
				"description": "RED (`http_requests_total`, `http_request_duration_seconds`) plus the edge " +
					"counters `gateway_rate_limited_total`, `gateway_upstream_errors_total`, " +
					"`gateway_jwks_refresh_total`. Closed-set labels only.",
				"responses": map[string]any{
					"200": map[string]any{
						"description": "Prometheus text format.",
						"content":     map[string]any{"text/plain": map[string]any{}},
					},
				},
			},
		},
		"/api/v1/bff/{path}": map[string]any{
			"get": map[string]any{
				"operationId": "getBffAggregate",
				"tags":        []string{"bff"}, "summary": "BFF aggregation (fan-out + stitch)",
				"description": "Bearer-required. Fans out to several upstreams and stitches one response " +
					"for a composite client screen.",
				"security": []map[string]any{{"bearerJwt": []string{}}},
				"parameters": []map[string]any{
					{"name": "path", "in": "path", "required": true,
						"schema": map[string]any{"type": "string"}, "description": "BFF sub-path."},
				},
				"responses": map[string]any{
					"200": jsonResp("Stitched aggregation response.", ""),
					"401": errRef("`token_invalid` — missing/invalid Bearer."),
					"403": errRef("`forbidden` — not permitted for this principal."),
					"429": errRef("`rate_limited` — token bucket exhausted."),
					"502": errRef("`upstream_error` — an aggregated upstream failed."),
					"504": errRef("`upstream_timeout` — an aggregated upstream timed out."),
				},
			},
		},
	}

	return map[string]any{
		"openapi": "3.0.3",
		"info": map[string]any{
			"title":       "DOKANDAR API Gateway",
			"version":     h.d.Code,
			"description": desc,
			"contact": map[string]any{
				"name":  "DOKANDAR Platform",
				"url":   "https://dokandar.com.bd",
				"email": "api@dokandar.com.bd",
			},
			"license": map[string]any{"name": "Proprietary"},
		},
		"servers": []map[string]any{
			{"url": "https://api.dokandar.com.bd", "description": "prod"},
			{"url": "http://localhost:10015", "description": "local"},
		},
		"tags": []map[string]any{
			{"name": "ops", "description": "The five operational endpoints (gateway-owned)."},
			{"name": "bff", "description": "BFF aggregation routes (fan-out + stitch)."},
		},
		"paths": paths,
		"components": map[string]any{
			"securitySchemes": map[string]any{
				// bearerJwt is the fleet-standard name (referenced on authed ops);
				// HTTPBearer is the historical alias kept for the smoke-test gate —
				// both describe the same RS256 access token verified at the edge.
				"bearerJwt":  map[string]any{"type": "http", "scheme": "bearer", "bearerFormat": "JWT"},
				"HTTPBearer": map[string]any{"type": "http", "scheme": "bearer", "bearerFormat": "JWT"},
			},
			"schemas": map[string]any{
				"Identity":      identitySchema,
				"ErrorEnvelope": errEnvelopeSchema,
				"ReadyBody": map[string]any{
					"type": "object",
					"properties": map[string]any{
						"status":       map[string]any{"type": "string", "example": "ready"},
						"identity":     map[string]any{"$ref": "#/components/schemas/Identity"},
						"dependencies": map[string]any{"type": "array", "items": map[string]any{}, "example": []any{}},
					},
				},
				"HealthBody": map[string]any{
					"type": "object",
					"properties": map[string]any{
						"status":   map[string]any{"type": "string", "example": "healthy"},
						"identity": map[string]any{"$ref": "#/components/schemas/Identity"},
						"checks": map[string]any{"type": "object", "additionalProperties": map[string]any{
							"type": "object",
							"properties": map[string]any{
								"ok":     map[string]any{"type": "boolean"},
								"detail": map[string]any{"type": "string"},
							},
						}},
						"upstreams": map[string]any{"type": "object", "additionalProperties": map[string]any{
							"type": "object",
							"properties": map[string]any{
								"ok":     map[string]any{"type": "boolean"},
								"detail": map[string]any{"type": "string"},
							},
						}},
						"observability": map[string]any{"type": "object"},
					},
				},
			},
		},
	}
}

// Docs serves a tiny self-contained Swagger UI page (raw HTML) that loads
// /openapi.json. CDN-pinned assets keep the binary small (no embedded bundle).
func (h *Handler) Docs(c echo.Context) error {
	// The Foundation's SecurityAndCORS middleware sets a strict
	// `Content-Security-Policy: default-src 'none'` BEFORE this handler runs —
	// that would block Swagger UI's CDN assets + its inline bootstrap script and
	// render a blank page. Relax the CSP for THIS route only to the CDN + inline,
	// so the docs page actually loads (the API routes keep the strict policy).
	c.Response().Header().Set("Content-Security-Policy",
		"default-src 'self'; "+
			"script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; "+
			"style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; "+
			"img-src 'self' data: https://cdn.jsdelivr.net; "+
			"connect-src 'self'")
	return c.HTML(http.StatusOK, swaggerHTML)
}

// swaggerHTML is the minimal Swagger-UI shell pointing at /openapi.json.
const swaggerHTML = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>15-api-gateway API</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui.css"/>
</head>
<body>
  <div id="swagger-ui"></div>
  <script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui-bundle.js" crossorigin></script>
  <script>
    window.onload = function () {
      window.ui = SwaggerUIBundle({
        url: "/openapi.json",
        dom_id: "#swagger-ui",
        deepLinking: true,
        persistAuthorization: true,
        presets: [SwaggerUIBundle.presets.apis],
        layout: "BaseLayout"
      });
    };
  </script>
</body>
</html>`
