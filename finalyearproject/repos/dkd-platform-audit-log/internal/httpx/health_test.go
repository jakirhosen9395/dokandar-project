package httpx

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHealth(t *testing.T) {
	rec := httptest.NewRecorder()
	health(rec, httptest.NewRequest(http.MethodGet, "/health", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("health = %d, want 200", rec.Code)
	}
}

// API Documentation Standard: Swagger UI at /docs, OpenAPI JSON at /swagger/v1/swagger.json + Bearer.
func TestAPIDocs(t *testing.T) {
	mux := http.NewServeMux()
	registerDocs(mux, "test-svc")
	for _, p := range []string{"/docs", "/swagger/v1/swagger.json"} {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, p, nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s = %d, want 200", p, rec.Code)
		}
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/swagger/v1/swagger.json", nil))
	if body := rec.Body.String(); !strings.Contains(body, "\"Bearer\"") || !strings.Contains(body, "\"version\": \"v1\"") {
		t.Fatalf("openapi doc missing Bearer scheme or version v1")
	}
}

func TestVersionUsesSDK(t *testing.T) {
	rec := httptest.NewRecorder()
	version(rec, httptest.NewRequest(http.MethodGet, "/version", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("version = %d", rec.Code)
	}
}
