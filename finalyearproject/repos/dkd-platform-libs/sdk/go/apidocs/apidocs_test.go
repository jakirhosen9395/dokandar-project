package apidocs

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestOpenAPIVersionPinned(t *testing.T) {
	if OpenAPIVersion != "3.1.0" {
		t.Fatalf("OpenAPIVersion = %q, want 3.1.0", OpenAPIVersion)
	}
	if !strings.Contains(openapiTemplate, `"openapi": "3.1.0"`) {
		t.Fatal("openapi template not pinned to 3.1.0")
	}
	if strings.Contains(openapiTemplate, `"openapi": "3.0`) {
		t.Fatal("openapi template still carries a 3.0.x version")
	}
}

func TestServedDocumentVersionIs310(t *testing.T) {
	mux := http.NewServeMux()
	Register(mux, "test-svc")

	req := httptest.NewRequest(http.MethodGet, "/swagger/v1/swagger.json", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	var doc map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &doc); err != nil {
		t.Fatalf("served doc not valid JSON: %v", err)
	}
	if doc["openapi"] != OpenAPIVersion {
		t.Fatalf("served openapi = %v, want %s", doc["openapi"], OpenAPIVersion)
	}
}
