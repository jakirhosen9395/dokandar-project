package dkdplatform

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestErrorClassHTTPStatus(t *testing.T) {
	cases := map[ErrorClass]int{
		ClassMalformed:     400,
		ClassValidation:    422,
		ClassAuthz:         403,
		ClassStateConflict: 409,
		ClassLocked:        423,
		ClassRateLimited:   429,
		ClassAccepted:      202,
		ClassUnavailable:   503,
	}
	for class, want := range cases {
		if got := class.HTTPStatus(); got != want {
			t.Errorf("class %d: status = %d, want %d", class, got, want)
		}
	}
}

func TestErrorConstructorsCarryStatus(t *testing.T) {
	cases := []struct {
		err  *DokandarError
		want int
	}{
		{NewMalformedError("c", "m"), 400},
		{NewUnprocessableError("c", "m"), 422},
		{NewForbiddenError("c", "m"), 403},
		{NewConflictError("c", "m"), 409},
		{NewLockedError("c", "m"), 423},
		{NewRateLimitError("c", "m"), 429},
		{NewUnavailableError("c", "m"), 503},
	}
	for _, tc := range cases {
		if tc.err.HTTPStatus != tc.want {
			t.Errorf("constructor status = %d, want %d", tc.err.HTTPStatus, tc.want)
		}
	}
}

func TestWriteProblemSetsRetryAfterOn429(t *testing.T) {
	rec := httptest.NewRecorder()
	WriteProblem(rec, NewRateLimitError("dokandar.platform.rate.throttled", "slow down"), 30)
	if rec.Code != 429 {
		t.Fatalf("status = %d, want 429", rec.Code)
	}
	if rec.Header().Get("Retry-After") != "30" {
		t.Fatalf("Retry-After = %q, want 30", rec.Header().Get("Retry-After"))
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/problem+json" {
		t.Fatalf("content-type = %q", ct)
	}
}

func TestWriteProblemNoRetryAfterOnNon429(t *testing.T) {
	rec := httptest.NewRecorder()
	WriteProblem(rec, NewConflictError("c", "m"), 30)
	if rec.Header().Get("Retry-After") != "" {
		t.Fatal("Retry-After should only be set on 429")
	}
	if rec.Code != http.StatusConflict {
		t.Fatalf("status = %d, want 409", rec.Code)
	}
}
