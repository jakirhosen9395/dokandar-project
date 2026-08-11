package search

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func fakeOS(t *testing.T, handler http.HandlerFunc) *Client {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	return New(srv.URL, "catalog-products")
}

func TestEnabled(t *testing.T) {
	if New("", "idx").Enabled() {
		t.Fatal("empty base URL must be disabled")
	}
	if !New("http://x:9200", "idx").Enabled() {
		t.Fatal("configured client must be enabled")
	}
	var nilClient *Client
	if nilClient.Enabled() {
		t.Fatal("nil client must be disabled")
	}
}

func TestIndexProductPutsDocByGPID(t *testing.T) {
	var gotPath string
	var gotDoc map[string]any
	c := fakeOS(t, func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.Method + " " + r.URL.Path
		_ = json.NewDecoder(r.Body).Decode(&gotDoc)
		w.WriteHeader(http.StatusCreated)
	})
	err := c.IndexProduct(context.Background(), "GP-rice-x", map[string]any{"namesBn": "চাল"})
	if err != nil {
		t.Fatal(err)
	}
	if gotPath != "PUT /catalog-products/_doc/GP-rice-x" {
		t.Fatalf("path: %s", gotPath)
	}
	if gotDoc["namesBn"] != "চাল" {
		t.Fatalf("doc: %v", gotDoc)
	}
}

func TestIndexProductSurfacesErrors(t *testing.T) {
	c := fakeOS(t, func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(500) })
	if err := c.IndexProduct(context.Background(), "g", nil); err == nil {
		t.Fatal("5xx must error")
	}
}

func TestDeleteTolerates404(t *testing.T) {
	c := fakeOS(t, func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(404) })
	if err := c.DeleteProduct(context.Background(), "g"); err != nil {
		t.Fatalf("404 on delete must be tolerated: %v", err)
	}
}

func TestSearchParsesHits(t *testing.T) {
	c := fakeOS(t, func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body["size"].(float64) != 20 { // default limit
			t.Errorf("size: %v", body["size"])
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"hits": map[string]any{"hits": []map[string]any{
				{"_source": map[string]any{"gpid": "GP-a-1"}},
				{"_source": map[string]any{"gpid": "GP-a-2"}},
			}},
		})
	})
	docs, err := c.Search(context.Background(), "চাল", 0)
	if err != nil || len(docs) != 2 || docs[0]["gpid"] != "GP-a-1" {
		t.Fatalf("docs=%v err=%v", docs, err)
	}
}

func TestPing(t *testing.T) {
	ok := fakeOS(t, func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })
	if err := ok.Ping(context.Background()); err != nil {
		t.Fatal(err)
	}
	bad := fakeOS(t, func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(503) })
	if err := bad.Ping(context.Background()); err == nil {
		t.Fatal("503 ping must error")
	}
}
