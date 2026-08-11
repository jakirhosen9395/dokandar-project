// Hand-authored primitive (PL-06). NOT dkdgen output: extends the coarse
// 400/409/503 error constructors in errors.go to the full canon HTTP-status
// vocabulary. Canon: EF-API-3 (problem+json status taxonomy). This splits the
// former one-size ValidationError (400) into 400-malformed vs 422-business-
// validation and adds 403/423/429/202 alongside the existing 409/503, plus a
// problem+json writer that emits Retry-After on 429.

package dkdplatform

import (
	"encoding/json"
	"net/http"
	"strconv"
)

// ErrorClass is the canon error family; each maps to exactly one HTTP status.
type ErrorClass int

const (
	// ClassMalformed — 400: syntactically bad request (unparseable body,
	// missing Idempotency-Key on an unsafe write). Distinct from Validation.
	ClassMalformed ErrorClass = iota
	// ClassValidation — 422: well-formed but business-invalid input.
	ClassValidation
	// ClassAuthz — 403: authz denial, incl. four-eyes second-approver rules.
	ClassAuthz
	// ClassStateConflict — 409: aggregate-state conflict or idempotency-key
	// replayed with a DIFFERENT payload.
	ClassStateConflict
	// ClassLocked — 423: park-and-freeze / fenced aggregate (SA-MSG-10).
	ClassLocked
	// ClassRateLimited — 429: throttled; carries Retry-After.
	ClassRateLimited
	// ClassAccepted — 202: async accepted (escrow/payout in flight).
	ClassAccepted
	// ClassUnavailable — 503: dependency/broker unavailable.
	ClassUnavailable
)

// HTTPStatus maps a class to its canonical HTTP status code.
func (c ErrorClass) HTTPStatus() int {
	switch c {
	case ClassMalformed:
		return http.StatusBadRequest // 400
	case ClassValidation:
		return http.StatusUnprocessableEntity // 422
	case ClassAuthz:
		return http.StatusForbidden // 403
	case ClassStateConflict:
		return http.StatusConflict // 409
	case ClassLocked:
		return http.StatusLocked // 423
	case ClassRateLimited:
		return http.StatusTooManyRequests // 429
	case ClassAccepted:
		return http.StatusAccepted // 202
	case ClassUnavailable:
		return http.StatusServiceUnavailable // 503
	default:
		return http.StatusInternalServerError // 500 — unreachable for a known class
	}
}

// NewError builds a *DokandarError with the status fixed by its class. The
// existing NewValidationError/NewBusinessError/NewInfrastructureError helpers in
// errors.go stay for back-compat; NewError covers the full vocabulary.
func NewError(class ErrorClass, code, message string) *DokandarError {
	return &DokandarError{Code: code, Message: message, HTTPStatus: class.HTTPStatus()}
}

// Explicit constructors for the added classes (mirrors the errors.go style).
func NewMalformedError(code, message string) *DokandarError {
	return NewError(ClassMalformed, code, message)
}
func NewUnprocessableError(code, message string) *DokandarError {
	return NewError(ClassValidation, code, message)
}
func NewForbiddenError(code, message string) *DokandarError {
	return NewError(ClassAuthz, code, message)
}
func NewConflictError(code, message string) *DokandarError {
	return NewError(ClassStateConflict, code, message)
}
func NewLockedError(code, message string) *DokandarError {
	return NewError(ClassLocked, code, message)
}
func NewRateLimitError(code, message string) *DokandarError {
	return NewError(ClassRateLimited, code, message)
}
func NewUnavailableError(code, message string) *DokandarError {
	return NewError(ClassUnavailable, code, message)
}

// WriteProblem emits an RFC-7807 problem+json response for a DokandarError. On
// a 429 it also sets Retry-After (seconds); pass retryAfterSeconds <= 0 to omit.
func WriteProblem(w http.ResponseWriter, e *DokandarError, retryAfterSeconds int) {
	if e.HTTPStatus == http.StatusTooManyRequests && retryAfterSeconds > 0 {
		w.Header().Set("Retry-After", strconv.Itoa(retryAfterSeconds))
	}
	w.Header().Set("Content-Type", "application/problem+json")
	w.WriteHeader(e.HTTPStatus)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"type":   "about:blank",
		"title":  http.StatusText(e.HTTPStatus),
		"status": e.HTTPStatus,
		"code":   e.Code,
		"detail": e.Message,
	})
}
