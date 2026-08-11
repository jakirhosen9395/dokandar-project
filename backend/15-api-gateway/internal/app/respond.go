package app

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"github.com/labstack/echo/v4"
)

// RequestIDKey is the echo.Context key under which the honour-or-mint request
// id is stashed by RequestID middleware. Handlers read it for the error
// envelope and log lines via RequestIDOf(c).
const RequestIDKey = "request_id"

// TrueIPKey is the echo.Context key under which TrueClientIP middleware stashes
// the derived client IP (the rate-limit key + access-log IP).
const TrueIPKey = "true_client_ip"

// UpstreamKey is the echo.Context key under which the proxy stashes the chosen
// upstream service name (e.g. "04-catalog") for the access log + metrics.
const UpstreamKey = "chosen_upstream"

// RequestIDOf returns the request id stashed on the context (empty if unset).
func RequestIDOf(c echo.Context) string {
	if v, ok := c.Get(RequestIDKey).(string); ok {
		return v
	}
	return ""
}

// TrueIPOf returns the derived true client IP (falls back to c.RealIP()).
func TrueIPOf(c echo.Context) string {
	if v, ok := c.Get(TrueIPKey).(string); ok && v != "" {
		return v
	}
	return c.RealIP()
}

// prettyBytes marshals v as 2-space-indented JSON with HTML escaping off
// (ensure_ascii=false — Bangla stays literal UTF-8) and a trailing newline.
func prettyBytes(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// PrettyJSON writes v as pretty JSON (indent 2 + trailing newline) with the
// given status and Content-Type application/json. This is the JSON writer every
// gateway-owned handler uses (ops, error envelopes) so the pretty-JSON contract
// holds. /metrics, /docs, /openapi.json do NOT use this (they are not JSON or
// are served raw).
func PrettyJSON(c echo.Context, status int, v any) error {
	b, err := prettyBytes(v)
	if err != nil {
		return err
	}
	return c.Blob(status, "application/json; charset=utf-8", b)
}

// ErrorEnvelope is the single error shape across the fleet:
//
//	{"error":{"code":"…","message":"…","request_id":"…","details":{…}?}}
//
// code is a stable machine token; details is optional.
func ErrorEnvelope(c echo.Context, status int, code, message string, details any) error {
	body := map[string]any{
		"code":       code,
		"message":    message,
		"request_id": RequestIDOf(c),
	}
	if details != nil {
		body["details"] = details
	}
	return PrettyJSON(c, status, map[string]any{"error": body})
}

// AccessLog emits one structured access-log line per request via slog (the
// 3-sink logger ships it to stdout + Mongo + ES). The route is the templated
// pattern; ip is the derived true client IP; upstream is the chosen proxy
// target ("" for gateway-owned routes). Called by AccessLogAndMetrics, which
// already excludes /ready,/metrics,/health.
func AccessLog(c echo.Context, method, route string, status int, latency time.Duration, upstream string) {
	attrs := []any{
		"name", "gateway.access",
		"method", method,
		"route", route,
		"status", status,
		"latency_ms", float64(latency.Microseconds()) / 1000.0,
		"client_ip", TrueIPOf(c),
		"request_id", RequestIDOf(c),
	}
	if upstream != "" {
		attrs = append(attrs, "upstream", upstream)
	}
	slog.InfoContext(c.Request().Context(), "request", attrs...)
}

// Bare404 emits the contract bare-404: status 404, Content-Length 0, NO body,
// NO Content-Type, no envelope. Echo's default 404 ships a JSON body, so the
// catch-all route and the HTTPErrorHandler must funnel unmapped paths here.
func Bare404(c echo.Context) error {
	h := c.Response().Header()
	h.Del(echo.HeaderContentType)
	h.Set(echo.HeaderContentLength, "0")
	c.Response().WriteHeader(http.StatusNotFound)
	return nil
}
