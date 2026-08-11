package dkdplatform

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// countingHandler records how many times the wrapped handler actually ran and
// echoes a fixed body, so a replay (handler NOT re-run) is observable.
func countingHandler(calls *int) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*calls++
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"ok":true}`)
	})
}

func TestIdempotencyMissingKeyRejected(t *testing.T) {
	store := NewMemIdempotencyStore()
	calls := 0
	h := IdempotencyMiddleware(store)(countingHandler(&calls))

	req := httptest.NewRequest(http.MethodPost, "/pay", strings.NewReader(`{"amt":1}`))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("missing key: status = %d, want 400", rec.Code)
	}
	if calls != 0 {
		t.Fatal("handler must not run when Idempotency-Key is missing")
	}
}

func TestIdempotencySamePayloadReplays(t *testing.T) {
	store := NewMemIdempotencyStore()
	calls := 0
	h := IdempotencyMiddleware(store)(countingHandler(&calls))

	do := func() *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/pay", strings.NewReader(`{"amt":1}`))
		req.Header.Set(IdempotencyKeyHeader, "key-abc")
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec
	}

	first := do()
	second := do()

	if calls != 1 {
		t.Fatalf("handler ran %d times; replay must not re-invoke it", calls)
	}
	if first.Code != http.StatusCreated || second.Code != http.StatusCreated {
		t.Fatalf("status mismatch: first=%d second=%d", first.Code, second.Code)
	}
	if first.Body.String() != second.Body.String() {
		t.Fatalf("replay body mismatch: %q vs %q", first.Body.String(), second.Body.String())
	}
	if second.Header().Get("Idempotency-Replayed") != "true" {
		t.Fatal("replayed response should be marked")
	}
}

func TestIdempotencyDifferentPayloadConflicts(t *testing.T) {
	store := NewMemIdempotencyStore()
	calls := 0
	h := IdempotencyMiddleware(store)(countingHandler(&calls))

	req1 := httptest.NewRequest(http.MethodPost, "/pay", strings.NewReader(`{"amt":1}`))
	req1.Header.Set(IdempotencyKeyHeader, "key-xyz")
	h.ServeHTTP(httptest.NewRecorder(), req1)

	req2 := httptest.NewRequest(http.MethodPost, "/pay", strings.NewReader(`{"amt":999}`))
	req2.Header.Set(IdempotencyKeyHeader, "key-xyz")
	rec2 := httptest.NewRecorder()
	h.ServeHTTP(rec2, req2)

	if rec2.Code != http.StatusConflict {
		t.Fatalf("different payload: status = %d, want 409", rec2.Code)
	}
	if calls != 1 {
		t.Fatalf("handler ran %d times; conflicting retry must not re-invoke it", calls)
	}
}

func TestIdempotencySafeMethodPassthrough(t *testing.T) {
	store := NewMemIdempotencyStore()
	calls := 0
	h := IdempotencyMiddleware(store)(countingHandler(&calls))

	req := httptest.NewRequest(http.MethodGet, "/status", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if calls != 1 {
		t.Fatal("safe GET must pass through without a key")
	}
}

// failingStore surfaces the store-unavailable branch.
type failingStore struct{}

func (failingStore) Lookup(context.Context, string) (IdempotencyRecord, bool, error) {
	return IdempotencyRecord{}, false, errors.New("boom")
}
func (failingStore) Save(context.Context, string, IdempotencyRecord) error { return nil }

func TestIdempotencyStoreErrorIs503(t *testing.T) {
	calls := 0
	h := IdempotencyMiddleware(failingStore{})(countingHandler(&calls))
	req := httptest.NewRequest(http.MethodPost, "/pay", strings.NewReader(`{}`))
	req.Header.Set(IdempotencyKeyHeader, "k")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("store error: status = %d, want 503", rec.Code)
	}
}
