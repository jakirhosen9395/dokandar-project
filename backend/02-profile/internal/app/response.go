// Package app holds the chi router wiring + cross-cutting middleware
// (pretty JSON, bare 404, request-id).
package app

import (
	"encoding/json"
	"net/http"

	"go.elastic.co/apm/v2"
)

// PrettyJSON writes v to w as indented JSON with the given status. The
// platform-wide pretty-print rule applies to every JSON response — see
// docs/contracts/service-contract.md §"Pretty JSON".
func PrettyJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

// ErrorBody is the platform-standard error envelope.
type ErrorBody struct {
	Error ErrorDetail `json:"error"`
}
type ErrorDetail struct {
	Code      string `json:"code"`
	Message   string `json:"message"`
	RequestID string `json:"request_id,omitempty"`
	Details   any    `json:"details,omitempty"`
}

// WriteError emits the standard envelope at the given status.
func WriteError(w http.ResponseWriter, r *http.Request, status int, code, message string, details any) {
	body := ErrorBody{Error: ErrorDetail{
		Code:      code,
		Message:   message,
		RequestID: r.Header.Get("X-Request-Id"),
		Details:   details,
	}}
	PrettyJSON(w, status, body)
}

// BareNotFound is the platform's info-hiding 404 — HTTP 404 with
// content-length: 0. Used as chi's NotFoundHandler so unmapped paths
// give no hint at the service surface.
func BareNotFound(w http.ResponseWriter, r *http.Request) {
	// Name the transaction so unmatched paths show as "<METHOD> unmatched" in Kibana APM
	// instead of the framework default "unknown route" (which the contract forbids).
	if tx := apm.TransactionFromContext(r.Context()); tx != nil {
		tx.Name = r.Method + " unmatched"
	}
	w.Header().Set("Content-Length", "0")
	w.WriteHeader(http.StatusNotFound)
}

// MethodNotAllowed keeps the envelope (405 on a KNOWN path is debug info
// a legitimate caller needs).
func MethodNotAllowed(w http.ResponseWriter, r *http.Request) {
	if tx := apm.TransactionFromContext(r.Context()); tx != nil {
		tx.Name = r.Method + " method-not-allowed"
	}
	WriteError(w, r, http.StatusMethodNotAllowed, "method_not_allowed", "Method Not Allowed", nil)
}
