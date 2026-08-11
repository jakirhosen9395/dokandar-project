package main

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
)

func testHandler(t *testing.T, upstream string) http.Handler {
	t.Helper()
	routes := []route{
		{"/v1/b2c/", upstream, true},
		{"/v1/catalog/", upstream, false},
	}
	return buildHandler(slog.New(slog.NewJSONHandler(os.Stderr, nil)), routes,
		newLimiter(6000, 100))
}

func TestUnsafeWriteWithoutIdemKeyIs400AtTheEdge(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer up.Close()
	h := testHandler(t, up.URL)
	req := httptest.NewRequest(http.MethodPost, "/v1/b2c/orders", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("want 400, got %d", rec.Code)
	}
	var p map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &p)
	if p["code"] != "dokandar.edge.request.idempotency_key_required" {
		t.Fatalf("wrong problem code: %v", p["code"])
	}
}

func TestReadsAndKeyedWritesProxyThrough(t *testing.T) {
	hits := 0
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits++
		w.WriteHeader(http.StatusOK)
	}))
	defer up.Close()
	h := testHandler(t, up.URL)

	get := httptest.NewRequest(http.MethodGet, "/v1/b2c/orders/ORD-1", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, get)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET should pass without a key, got %d", rec.Code)
	}

	post := httptest.NewRequest(http.MethodPost, "/v1/b2c/orders", nil)
	post.Header.Set("Idempotency-Key", "k1")
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, post)
	if rec.Code != http.StatusOK {
		t.Fatalf("keyed POST should pass, got %d", rec.Code)
	}
	if hits != 2 {
		t.Fatalf("expected 2 upstream hits, got %d", hits)
	}
}

func TestInternalSeamsAreNeverExposed(t *testing.T) {
	h := testHandler(t, "http://127.0.0.1:1")
	req := httptest.NewRequest(http.MethodGet, "/internal/orders/ORD-1", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("internal seam must 404 at the edge, got %d", rec.Code)
	}
}

func TestRateLimit429CarriesRetryAfter(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer up.Close()
	routes := []route{{"/v1/catalog/", up.URL, false}}
	h := buildHandler(slog.New(slog.NewJSONHandler(os.Stderr, nil)), routes, newLimiter(1, 1))
	req := httptest.NewRequest(http.MethodGet, "/v1/catalog/products", nil)
	req.RemoteAddr = "10.0.0.9:1234"
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req) // consumes the single token
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("want 429, got %d", rec.Code)
	}
	if rec.Header().Get("Retry-After") == "" {
		t.Fatal("429 must carry Retry-After (EF 7.6.1)")
	}
}

func TestUnknownRouteIsProblemJSON(t *testing.T) {
	h := testHandler(t, "http://127.0.0.1:1")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/nope/x", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("want 404, got %d", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/problem+json" {
		t.Fatalf("want problem+json, got %s", ct)
	}
}
