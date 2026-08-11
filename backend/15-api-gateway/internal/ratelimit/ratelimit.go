// Package ratelimit is the gateway's DISTRIBUTED rate-limiter: a fixed-window
// token bucket backed by Redis DB 13 (the gateway's only datastore). It is NOT
// an in-memory limiter — every gateway replica shares one counter per key in
// Redis, so the limit is fleet-wide, not per-pod (architecture.md §16-d).
//
// Seam with the foundation (cmd/gateway/main.go, frozen):
//
//	limiter := ratelimit.New(rdb, ratelimit.Config{Max: …, WindowMS: …})
//	router  := proxy.New(proxy.Config{…}, verifier, limiter)
//
// main.go constructs ONE *Limiter and hands it to the proxy. The proxy then
// derives a per-route echo.MiddlewareFunc by calling:
//
//	storefront (fail-open): lim.Limit(0, 0, true)
//	sensitive  (fail-closed): lim.Limit(0, 0, false)
//
// A 0 for maxPerWindow/windowMS falls back to the constructed Config defaults,
// so the proxy can pass per-route overrides or just reuse the global budget.
//
// Degradability is the load-bearing property: the front door must never be
// pulled down by a Redis blip. A nil client (REDIS_HOST empty → db.NewRedis
// returned (nil,nil)) and any Redis error degrade per the per-route policy —
//
//	failOpen  → allow the request (storefront reads stay up under a Redis blip);
//	!failOpen → 429 rate_limited (sensitive routes fail CLOSED).
//
// The route LABEL on the metric + the error is the templated c.Path() (a
// closed-set token), NEVER the principal or client IP (those would explode
// cardinality and leak PII into series labels — architecture.md §11/§16).
package ratelimit

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/labstack/echo/v4"
	"github.com/redis/go-redis/v9"

	"github.com/dokandar/dokandar-gateway/internal/observability"
)

// keyPrefix namespaces every bucket key in Redis DB 13.
const keyPrefix = "ratelimit:"

// redisOpTimeout bounds the INCR+PEXPIRE round-trip. It is a small FIXED budget,
// deliberately decoupled from the rate-limit window: a HUNG (not failed) Redis
// must trip the degrade path in ~250ms, not stall the front door for a whole
// (possibly multi-second) window — that would defeat "a Redis blip never pulls
// the single front door" (architecture.md §8.1/§16-a/§16-d).
const redisOpTimeout = 250 * time.Millisecond

// requestIDHeader is the response header RequestID middleware (foundation) sets
// to the honour-or-mint id. ratelimit reads it back here instead of importing
// internal/app (avoids a potential app↔proxy↔ratelimit import cycle).
const requestIDHeader = echo.HeaderXRequestID

// tokenBucketLua is an atomic fixed-window counter: INCR the key, and on the
// FIRST hit of a fresh window stamp the TTL (PEXPIRE windowMS). It returns the
// post-increment count so the caller decides allow/deny. Doing the INCR+EXPIRE
// in one server-side script is what makes the limit correct under concurrency
// (two replicas racing the first hit cannot both skip the EXPIRE and leak an
// immortal counter).
//
//	KEYS[1] = bucket key
//	ARGV[1] = window in milliseconds
//	returns = the new counter value (int)
const tokenBucketLua = `
local n = redis.call("INCR", KEYS[1])
if n == 1 then
  redis.call("PEXPIRE", KEYS[1], ARGV[1])
end
return n
`

var tokenBucketScript = redis.NewScript(tokenBucketLua)

// Config is the global rate-limit budget the foundation's main.go constructs
// the limiter with. Field names (Max, WindowMS) are the frozen seam — do not
// rename. Max ≤ 0 or WindowMS ≤ 0 falls back to safe defaults.
type Config struct {
	Max      int // requests permitted per window (default 120)
	WindowMS int // window length in milliseconds (default 1000)
}

func (c Config) withDefaults() Config {
	if c.Max <= 0 {
		c.Max = 120
	}
	if c.WindowMS <= 0 {
		c.WindowMS = 1000
	}
	return c
}

// Limiter holds the shared Redis client + the global default budget. Construct
// once (main.go) and reuse — Limit() derives per-route middleware off it.
type Limiter struct {
	rdb     *redis.Client
	defMax  int
	defWinM int
}

// New builds the limiter. rdb may be nil (Redis disabled / connect failed) —
// the limiter then degrades per the per-route policy and NEVER panics. Matches
// the frozen call in cmd/gateway/main.go: ratelimit.New(rdb, ratelimit.Config{…}).
func New(rdb *redis.Client, cfg Config) *Limiter {
	cfg = cfg.withDefaults()
	return &Limiter{rdb: rdb, defMax: cfg.Max, defWinM: cfg.WindowMS}
}

// Limit returns an Echo middleware enforcing maxPerWindow requests per windowMS,
// keyed by "ratelimit:<principal-or-ip>:<route>". A 0 for maxPerWindow or
// windowMS falls back to the limiter's constructed defaults, so the proxy can
// pass route-specific budgets or reuse the global one.
//
// failOpen is the per-route degradation policy when Redis is unavailable:
//
//	true  (storefront: catalog/search public reads) → allow on Redis error;
//	false (sensitive: cart/order/wallet/payment)    → 429 on Redis error.
//
// Over the limit (or a fail-closed Redis error) → 429 with the error envelope
// {error:{code:"rate_limited",…}} and gateway_rate_limited_total{service,route}++.
// The route LABEL is the templated c.Path() (closed-set), never the IP/principal.
func (l *Limiter) Limit(maxPerWindow, windowMS int, failOpen bool) echo.MiddlewareFunc {
	max := maxPerWindow
	if max <= 0 {
		max = l.defMax
	}
	winMS := windowMS
	if winMS <= 0 {
		winMS = l.defWinM
	}

	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			// Redis disabled (nil client) → degrade by policy, no key work.
			if l.rdb == nil {
				if failOpen {
					return next(c)
				}
				return l.reject(c)
			}

			key := keyPrefix + subject(c) + ":" + c.Path()

			// Bound the round-trip to a small FIXED budget (decoupled from the
			// window) so a hung Redis degrades fast instead of stalling the door.
			ctx, cancel := context.WithTimeout(c.Request().Context(), redisOpTimeout)
			res, err := tokenBucketScript.Run(ctx, l.rdb, []string{key}, strconv.Itoa(winMS)).Result()
			cancel()
			if err != nil {
				// Redis blip → degrade by policy. A fail-closed reject still
				// counts as a shed request on the metric.
				if failOpen {
					return next(c)
				}
				return l.reject(c)
			}

			count, _ := res.(int64)
			if count > int64(max) {
				return l.reject(c)
			}
			return next(c)
		}
	}
}

// subject is the rate-limit principal: the authenticated subject if a later
// gate stashed one, else the derived true client IP (c.RealIP() — already the
// CF-Connecting-IP / trusted-XFF value the foundation's IPExtractor produced).
// "principal-or-ip" with the IP as the safe fallback; the foundation defines no
// principal context key yet, so today this is always the IP.
func subject(c echo.Context) string {
	for _, k := range []string{"principal", "user_id", "subject"} {
		if v, ok := c.Get(k).(string); ok && v != "" {
			return v
		}
	}
	if ip := c.RealIP(); ip != "" {
		return ip
	}
	return "anon"
}

// reject emits the 429 + bumps the closed-set metric. The route label is the
// templated c.Path() (never the IP/principal).
func (l *Limiter) reject(c echo.Context) error {
	observability.GatewayRateLimitedTotal.
		WithLabelValues(observability.ServiceVal, c.Path()).Inc()
	return writeRateLimited(c)
}

// writeRateLimited writes the contract 429 error envelope inline (pretty-JSON,
// indent 2, ensure_ascii=false), mirroring internal/app.ErrorEnvelope without
// importing internal/app. request_id is read back from the X-Request-Id
// response header the foundation's RequestID middleware already set.
func writeRateLimited(c echo.Context) error {
	body := map[string]any{
		"error": map[string]any{
			"code":       "rate_limited",
			"message":    "rate limit exceeded",
			"request_id": c.Response().Header().Get(requestIDHeader),
		},
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(body); err != nil {
		return err
	}
	return c.Blob(http.StatusTooManyRequests, "application/json; charset=utf-8", buf.Bytes())
}
