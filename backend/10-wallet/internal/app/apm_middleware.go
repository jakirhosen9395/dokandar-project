package app

import (
	"fmt"
	"log/slog"
	"time"

	"github.com/gofiber/fiber/v3"
	"go.elastic.co/apm/v2"
)

// accessLogMiddleware emits ONE structured access line per request via
// slog.InfoContext(c.Context(), …). Because apmMiddleware already stored the APM
// transaction on c.Context(), the slog handler stamps the ECS trace context
// (trace.id/transaction.id) → the line correlates with its transaction in Kibana
// APM and lands structured in the ES/Mongo sinks. Excludes the LB-probe paths.
func accessLogMiddleware() fiber.Handler {
	return func(c fiber.Ctx) error {
		start := time.Now()
		err := c.Next()
		switch c.Path() {
		case "/ready", "/metrics", "/health":
			return err
		}
		slog.InfoContext(c.Context(), "access",
			"method", c.Method(),
			"route", routePattern(c),
			"status", c.Response().StatusCode(),
			"duration_ms", float64(time.Since(start).Microseconds())/1000.0,
			"request_id", fmt.Sprint(c.Locals("request_id")),
			"client_ip", c.IP(),
		)
		return err
	}
}

// apmMiddleware is the OUTERMOST middleware (registered first). There is no
// apmfiber build for Fiber v3, so this is the manual equivalent: it starts an
// APM transaction, puts it on a context.Context, and sets that context on the
// Fiber ctx via c.SetContext(...) — so every handler that calls c.Context()
// (and therefore every GORM query + every log line) nests under this
// transaction and carries the trace id. On finish it stamps the HTTP result
// and ends the transaction.
//
// Per the contract, APM is diagnostic: if the tracer is unconfigured the
// transaction is a no-op and the request still flows.
func apmMiddleware(tracer *apm.Tracer) fiber.Handler {
	return func(c fiber.Ctx) error {
		// Start the transaction with a provisional name; the matched route is
		// not known until routing runs (after c.Next()), so rename then.
		tx := tracer.StartTransaction(c.Method(), "request")
		// Carry the transaction in the request context for handlers + GORM + logs.
		ctx := apm.ContextWithTransaction(c.Context(), tx)
		c.SetContext(ctx)

		err := c.Next()

		tx.Name = c.Method() + " " + routePattern(c) // route resolved now
		status := c.Response().StatusCode()
		tx.Context.SetHTTPStatusCode(status)
		tx.Result = fmt.Sprintf("HTTP %dxx", status/100)
		tx.End()
		return err
	}
}

// routePattern returns the matched route template (bounded cardinality, never
// a raw path with UUIDs). Falls back to "unmatched".
func routePattern(c fiber.Ctx) string {
	if r := c.Route(); r != nil && r.Path != "" {
		return r.Path
	}
	return "unmatched"
}
