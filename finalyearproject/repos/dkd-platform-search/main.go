// search-svc — DOKANDAR platform #30 (PLAT-01). The single authoritative cross-context SEARCH plane
// (FR-MKT-013 / G12): a unified OpenSearch index that any context can push documents to, plus a
// query API. OpenSearch is the ONLY sanctioned business-search engine (System-Architecture §8.1).
//
// MVP surface: POST /v1/index (upsert a cross-context doc) + GET /v1/search?q= (multi_match). Event-
// driven auto-indexing off the spine is a documented follow-up; the plane + index/query are live here.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

var (
	log       = slog.New(slog.NewJSONHandler(os.Stdout, nil))
	searchURL = strings.TrimRight(env("DKD_SEARCH_URL", "http://172.31.45.156:9201"), "/")
	index     = env("DKD_SEARCH_INDEX", "dkd-search")
	httpPort  = env("DKD_HTTP_PORT", "8080")
	gitSha    = env("DKD_GIT_SHA", "unknown")
	version   = env("DKD_VERSION", "0.1.0")
	hc        = &http.Client{Timeout: 10 * time.Second}
)

// Document is a cross-context searchable record. `kind` namespaces the source (product|order|party|…);
// canonical IDs only — never PII on the shared index (R6).
type Document struct {
	Kind   string         `json:"kind"`
	ID     string         `json:"id"`
	Text   string         `json:"text"`
	Fields map[string]any `json:"fields,omitempty"`
}

func osDo(ctx context.Context, method, path string, body any) (int, []byte, error) {
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, searchURL+path, rd)
	if err != nil {
		return 0, nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := hc.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	return resp.StatusCode, out, nil
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func problem(w http.ResponseWriter, status int, code, detail string) {
	w.Header().Set("Content-Type", "application/problem+json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{"type": "about:blank", "status": status, "code": code, "detail": detail})
}

// indexHandler upserts a document keyed by "<kind>:<id>" into the unified index.
func indexHandler(w http.ResponseWriter, r *http.Request) {
	var d Document
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&d); err != nil {
		problem(w, http.StatusBadRequest, "dokandar.platform.search.invalid_json", err.Error())
		return
	}
	if d.Kind == "" || d.ID == "" {
		problem(w, http.StatusUnprocessableEntity, "dokandar.platform.search.invalid_doc", "kind and id are required")
		return
	}
	docID := d.Kind + ":" + d.ID
	status, body, err := osDo(r.Context(), http.MethodPut, "/"+index+"/_doc/"+docID+"?refresh=true", d)
	if err != nil {
		problem(w, http.StatusServiceUnavailable, "dokandar.platform.search.engine", err.Error())
		return
	}
	if status >= 300 {
		problem(w, http.StatusBadGateway, "dokandar.platform.search.index_failed", string(body))
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"success": true, "data": map[string]any{"id": docID, "indexed": true}, "error": nil})
}

// searchHandler runs a multi_match over the unified index and returns the hits.
func searchHandler(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if q == "" {
		problem(w, http.StatusUnprocessableEntity, "dokandar.platform.search.missing_query", "query parameter q is required")
		return
	}
	// best_fields (default) works across mixed text+keyword fields; phrase_prefix would reject the
	// keyword fields (kind/id). text is boosted so free-text relevance dominates.
	query := map[string]any{
		"size":  20,
		"query": map[string]any{"multi_match": map[string]any{"query": q, "fields": []string{"text^2", "id", "kind"}}},
	}
	status, body, err := osDo(r.Context(), http.MethodPost, "/"+index+"/_search", query)
	if err != nil {
		problem(w, http.StatusServiceUnavailable, "dokandar.platform.search.engine", err.Error())
		return
	}
	if status >= 300 {
		problem(w, http.StatusBadGateway, "dokandar.platform.search.query_failed", string(body))
		return
	}
	var parsed struct {
		Hits struct {
			Total struct{ Value int } `json:"total"`
			Hits  []struct {
				Source Document `json:"_source"`
			} `json:"hits"`
		} `json:"hits"`
	}
	_ = json.Unmarshal(body, &parsed)
	results := make([]Document, 0, len(parsed.Hits.Hits))
	for _, h := range parsed.Hits.Hits {
		results = append(results, h.Source)
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "data": map[string]any{"query": q, "total": parsed.Hits.Total.Value, "results": results}, "error": nil, "meta": map[string]any{"asOf": time.Now().UnixMilli()}})
}

func main() {
	// ensure the unified index exists (idempotent).
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	if st, _, err := osDo(ctx, http.MethodPut, "/"+index, map[string]any{
		"mappings": map[string]any{"properties": map[string]any{
			"kind": map[string]any{"type": "keyword"}, "id": map[string]any{"type": "keyword"}, "text": map[string]any{"type": "text"},
		}},
	}); err != nil {
		log.Warn("search index create skipped (engine unreachable at boot)", "err", err.Error())
	} else {
		log.Info("search index ensured", "index", index, "status", st)
	}
	cancel()

	mux := http.NewServeMux()
	build := map[string]any{"service": "search-svc", "version": version, "gitSha": gitSha}
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) { writeJSON(w, 200, map[string]any{"success": true, "data": map[string]any{"status": "ok", "service": "search-svc", "gitSha": gitSha}, "error": nil}) })
	mux.HandleFunc("GET /live", func(w http.ResponseWriter, _ *http.Request) { writeJSON(w, 200, map[string]any{"success": true, "data": map[string]any{"status": "ok"}, "error": nil}) })
	mux.HandleFunc("GET /ready", func(w http.ResponseWriter, r *http.Request) {
		st, _, err := osDo(r.Context(), http.MethodGet, "/", nil)
		if err != nil || st >= 300 {
			writeJSON(w, 503, map[string]any{"success": false, "data": map[string]any{"status": "degraded", "engine": false}, "error": nil})
			return
		}
		writeJSON(w, 200, map[string]any{"success": true, "data": map[string]any{"status": "ready", "engine": true}, "error": nil})
	})
	mux.HandleFunc("GET /version", func(w http.ResponseWriter, _ *http.Request) { writeJSON(w, 200, map[string]any{"success": true, "data": build, "error": nil}) })
	mux.HandleFunc("POST /v1/index", indexHandler)
	mux.HandleFunc("GET /v1/search", searchHandler)

	srv := &http.Server{Addr: "0.0.0.0:" + httpPort, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		log.Info("search-svc started", "port", httpPort, "engine", searchURL, "index", index)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Error("listen failed", "err", err.Error())
			os.Exit(1)
		}
	}()
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	sc, cc := context.WithTimeout(context.Background(), 10*time.Second)
	defer cc()
	_ = srv.Shutdown(sc)
	fmt.Println("search-svc stopped")
}
