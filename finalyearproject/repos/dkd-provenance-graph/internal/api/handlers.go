// Package api serves the provenance/recall READ surface (context #4 owns no registered OHS —
// REST substitution, Phase-2 contract pending). Every response carries meta.asOf = the graph's
// custody watermark (G11 staleness stamping).
package api

import (
	"encoding/json"
	"net/http"
	"time"

	"log/slog"

	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"

	"gitlab.com/final-year-project3354127/provenance-svc/internal/graph"
	"gitlab.com/final-year-project3354127/provenance-svc/internal/obs"
)

type Metrics interface{ Inc(name string) }

type API struct {
	g   *graph.Client
	m   Metrics
	log *slog.Logger
	now func() int64
}

func New(g *graph.Client, m Metrics, log *slog.Logger, now func() int64) *API {
	return &API{g: g, m: m, log: log, now: now}
}

func (a *API) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/provenance/{ppid}", a.getPassport)
	mux.HandleFunc("GET /v1/provenance/{ppid}/lineage", a.lineage)
	mux.HandleFunc("GET /v1/recalls/{recallId}/scope", a.scope)
}

func code(category, reason string) string {
	c, err := dkd.ErrorCode("provenance", category, reason)
	if err != nil {
		return "dokandar.provenance.internal.bad_code"
	}
	return c
}

func writeJSON(w http.ResponseWriter, status int, ct string, body any) {
	w.Header().Set("Content-Type", ct)
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func (a *API) meta(r *http.Request) map[string]any {
	asOf, err := a.g.Watermark(r.Context())
	if err != nil {
		a.log.Warn("watermark read failed", "err", err)
	}
	// PRV-10: richer meta — requestId (from the correlation middleware) + response timestamp,
	// alongside the graph watermark asOf.
	return map[string]any{
		"asOf":      asOf,
		"requestId": obs.CorrelationID(r.Context()),
		"timestamp": time.Now().UnixMilli(),
	}
}

// PRV-10: reject a malformed PPID at the boundary (well-formed request, invalid VALUE → 422).
func (a *API) validPPID(w http.ResponseWriter, ppid string) bool {
	if _, err := dkd.NewPPID(ppid); err != nil {
		writeProblem(w, http.StatusUnprocessableEntity, code("validation", "ppid"),
			"invalid ppid", "ppid must be a PP-<uuid7> identifier")
		return false
	}
	return true
}

func writeData(w http.ResponseWriter, status int, data any, meta map[string]any) {
	writeJSON(w, status, "application/json", map[string]any{
		"success": true, "data": data, "error": nil, "meta": meta,
	})
}

func writeProblem(w http.ResponseWriter, status int, codeStr, title, detail string) {
	writeJSON(w, status, "application/problem+json", map[string]any{
		"type": "about:blank", "title": title, "status": status, "code": codeStr, "detail": detail,
	})
}

func (a *API) getPassport(w http.ResponseWriter, r *http.Request) {
	if !a.validPPID(w, r.PathValue("ppid")) {
		return
	}
	node, err := a.g.GetPassport(r.Context(), r.PathValue("ppid"))
	if err != nil {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "graph"), "graph failure", err.Error())
		return
	}
	if node == nil {
		writeProblem(w, http.StatusNotFound, code("not_found", "passport"), "passport not in graph", r.PathValue("ppid"))
		return
	}
	writeData(w, http.StatusOK, node, a.meta(r))
}

func (a *API) lineage(w http.ResponseWriter, r *http.Request) {
	if !a.validPPID(w, r.PathValue("ppid")) {
		return
	}
	nodes, err := a.g.Lineage(r.Context(), r.PathValue("ppid"))
	if err != nil {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "graph"), "graph failure", err.Error())
		return
	}
	if nodes == nil {
		writeProblem(w, http.StatusNotFound, code("not_found", "passport"), "passport not in graph", r.PathValue("ppid"))
		return
	}
	writeData(w, http.StatusOK, nodes, a.meta(r))
}

func (a *API) scope(w http.ResponseWriter, r *http.Request) {
	scope, err := a.g.Scope(r.Context(), r.PathValue("recallId"), a.now())
	if err != nil {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "graph"), "graph failure", err.Error())
		return
	}
	if scope == nil {
		writeProblem(w, http.StatusNotFound, code("not_found", "recall"), "recall case not found", r.PathValue("recallId"))
		return
	}
	writeData(w, http.StatusOK, scope, a.meta(r))
}
