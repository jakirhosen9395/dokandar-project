package app

import (
	"errors"
	"time"

	"github.com/gofiber/fiber/v3"
	recoverer "github.com/gofiber/fiber/v3/middleware/recover"
	"github.com/gofiber/fiber/v3/middleware/requestid"
	"go.elastic.co/apm/v2"

	"github.com/dokandar/dokandar-wallet/internal/auth"
	"github.com/dokandar/dokandar-wallet/internal/handler"
	"github.com/dokandar/dokandar-wallet/internal/observability"
)

type Deps struct {
	Ops      *handler.Ops
	Wallet   *handler.Wallet
	Verifier *auth.Verifier
	Tracer   *apm.Tracer
}

// New builds the Fiber v3 app: pretty-JSON, the error envelope, middleware
// ordered APM(first) → request-id → recover → metrics, the five ops endpoints,
// the wallet business API, and a bare-404 catch-all.
func New(d Deps) *fiber.App {
	tracer := d.Tracer
	if tracer == nil {
		tracer = apm.DefaultTracer()
	}

	app := fiber.New(fiber.Config{
		AppName:       "dokandar-wallet",
		StrictRouting: false,
		CaseSensitive: false,
		JSONEncoder:   prettyJSONEncoder,
		ErrorHandler:  errorHandler,
	})

	// 1) APM transaction — OUTERMOST (no apmfiber for v3).
	app.Use(apmMiddleware(tracer))
	// 2) honour-or-mint x-request-id (requestid reuses an inbound header value).
	app.Use(requestid.New(requestid.Config{Header: fiber.HeaderXRequestID}))
	// stash the id under a stable Locals key for the error envelope + handlers.
	app.Use(func(c fiber.Ctx) error {
		c.Locals("request_id", requestid.FromContext(c))
		return c.Next()
	})
	// 3) recover panics → ErrorHandler.
	app.Use(recoverer.New())
	// 4) RED metrics.
	app.Use(metricsMiddleware())
	// 5) structured, trace-correlated access log (slog.InfoContext on c.Context()).
	app.Use(accessLogMiddleware())

	// ----- Ops (public, no auth) -----
	app.Get("/ready", d.Ops.Ready)
	app.Get("/health", d.Ops.Health)
	app.Get("/data", d.Ops.Data)
	app.Get("/metrics", d.Ops.Metrics)
	app.Get("/docs", func(c fiber.Ctx) error {
		c.Set("Content-Type", "text/html; charset=utf-8")
		return c.SendString(swaggerHTML)
	})
	app.Get("/openapi.json", func(c fiber.Ctx) error {
		return c.JSON(openapiSpec(d.Ops.Settings.ServiceName))
	})

	// ----- Business API -----
	// Per-route middleware (variadic handlers) so each guard is scoped to
	// exactly its route. An empty-prefix Group("", mw) would instead register
	// mw as a prefix-Use that leaks onto every later route under the prefix.
	api := app.Group("/api/v1/wallet")

	// Authenticated (customer JWT).
	api.Get("/me", d.Verifier.RequireUser(), d.Wallet.Me)
	api.Get("/me/entries", d.Verifier.RequireUser(), d.Wallet.Entries)
	api.Post("/me/topup", d.Verifier.RequireUser(), d.Wallet.Topup)

	// Public read (no auth).
	api.Get("/cashback-rules", d.Wallet.ListCashbackRules)

	// East-west (x-internal-token, constant-time).
	api.Post("/debit", d.Verifier.RequireInternalToken(), d.Wallet.Debit)
	api.Post("/credit", d.Verifier.RequireInternalToken(), d.Wallet.Credit)
	api.Get("/balance/:user_id", d.Verifier.RequireInternalToken(), d.Wallet.Balance)

	// ----- Bare-404 catch-all (LAST). No body, no Content-Type, Content-Length 0.
	app.Use(func(c fiber.Ctx) error {
		c.Status(fiber.StatusNotFound)
		c.Response().Header.Del(fiber.HeaderContentType)
		c.Response().ResetBody()
		return nil
	})

	return app
}

// errorHandler renders the single error envelope and never leaks raw 5xx
// internals to the client (the raw error is logged by recover/handlers).
func errorHandler(c fiber.Ctx, err error) error {
	code := fiber.StatusInternalServerError
	msg := "internal_error"
	machine := "internal_error"
	var fe *fiber.Error
	if errors.As(err, &fe) {
		code = fe.Code
		msg = fe.Message
		machine = msg
	}
	if code >= 500 {
		msg = "internal error"
		machine = "internal_error"
	}
	rid, _ := c.Locals("request_id").(string)
	c.Status(code)
	return c.JSON(fiber.Map{
		"error": fiber.Map{"code": machine, "message": msg, "request_id": rid},
	})
}

// metricsMiddleware records http_requests_total + duration with the matched
// route pattern (bounded cardinality) and a closed-set status token.
func metricsMiddleware() fiber.Handler {
	return func(c fiber.Ctx) error {
		start := time.Now()
		err := c.Next()
		route := "unmatched"
		if r := c.Route(); r != nil && r.Path != "" {
			route = r.Path
		}
		method := c.Method()
		status := statusToken(c.Response().StatusCode())
		observability.HTTPRequestsTotal.WithLabelValues(observability.ServiceVal, method, route, status).Inc()
		observability.HTTPRequestDuration.WithLabelValues(observability.ServiceVal, method, route).
			Observe(time.Since(start).Seconds())
		return err
	}
}

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
