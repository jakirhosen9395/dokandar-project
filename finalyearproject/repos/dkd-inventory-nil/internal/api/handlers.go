// Package api is inventory-svc's G2 seam as REST (gRPC OHS proto is NEEDS-INFO — documented
// substitution behind stable routes): Reserve / Release / Confirm / GetLocalStock, plus the
// NIL rollup read (always stamped with meta.asOf + lagMs — G11).
package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"

	"log/slog"

	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"

	"gitlab.com/final-year-project3354127/inventory-svc/internal/store"
)

const (
	MetricReservations = "inventory_reservations_total"
	MetricInsufficient = "inventory_insufficient_total"
)

type Store interface {
	Reserve(ctx context.Context, idemKey, gpid, holder string, qty, at int64) (store.Reservation, error)
	Transition(ctx context.Context, resID, to string, at int64) (store.Reservation, error)
	Local(ctx context.Context, gpid, holder string) (store.LocalStock, error)
	NIL(ctx context.Context, gpid string, at int64) (store.NILRollup, error)
}

type Metrics interface{ Inc(name string) }

type API struct {
	st  Store
	m   Metrics
	log *slog.Logger
	now func() int64
}

func New(st Store, m Metrics, log *slog.Logger, now func() int64) *API {
	return &API{st: st, m: m, log: log, now: now}
}

func (a *API) Register(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/inventory/reservations", a.reserve)
	mux.HandleFunc("POST /v1/inventory/reservations/{id}/release", a.release)
	mux.HandleFunc("POST /v1/inventory/reservations/{id}/confirm", a.confirm)
	mux.HandleFunc("GET /v1/inventory/local", a.local)
	mux.HandleFunc("GET /v1/inventory/nil/{gpid}", a.nilRollup)
}

func code(category, reason string) string {
	c, err := dkd.ErrorCode("inventory", category, reason)
	if err != nil {
		return "dokandar.inventory.internal.bad_code"
	}
	return c
}

func writeJSON(w http.ResponseWriter, status int, ct string, body any) {
	w.Header().Set("Content-Type", ct)
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func writeData(w http.ResponseWriter, status int, data any, meta map[string]any) {
	env := map[string]any{"success": true, "data": data, "error": nil}
	if meta != nil {
		env["meta"] = meta
	}
	writeJSON(w, status, "application/json", env)
}

func writeProblem(w http.ResponseWriter, status int, codeStr, title, detail string) {
	writeJSON(w, status, "application/problem+json", map[string]any{
		"type": "about:blank", "title": title, "status": status, "code": codeStr, "detail": detail,
	})
}

type reserveReq struct {
	GPID     string `json:"gpid"`
	Holder   string `json:"holder"`
	Quantity int64  `json:"quantity"`
}

// reserve: Idempotency-Key IS the reservation idempotency key (G2 idempotent command).
func (a *API) reserve(w http.ResponseWriter, r *http.Request) {
	key := r.Header.Get("Idempotency-Key")
	if key == "" {
		writeProblem(w, http.StatusBadRequest, code("validation", "idempotency_key_required"),
			"Idempotency-Key required", "Reserve is an idempotent command (G2)")
		return
	}
	var req reserveReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeProblem(w, http.StatusBadRequest, code("validation", "invalid_json"), "invalid JSON", err.Error())
		return
	}
	// INV-06 / EF-API-3: well-formed request, invalid VALUE → 422 (malformed JSON / missing header stay 400).
	if _, err := dkd.NewGPID(req.GPID); err != nil {
		writeProblem(w, http.StatusUnprocessableEntity, code("validation", "gpid"), "invalid gpid", err.Error())
		return
	}
	if _, err := dkd.NewDID(req.Holder); err != nil {
		writeProblem(w, http.StatusUnprocessableEntity, code("validation", "holder"), "invalid holder DID", err.Error())
		return
	}
	if req.Quantity <= 0 {
		writeProblem(w, http.StatusUnprocessableEntity, code("validation", "quantity"), "invalid quantity", "quantity must be a positive integer")
		return
	}
	res, err := a.st.Reserve(r.Context(), key, req.GPID, req.Holder, req.Quantity, a.now())
	if err != nil {
		if errors.Is(err, store.ErrInsufficientStock) {
			a.m.Inc(MetricInsufficient)
			writeProblem(w, http.StatusConflict, code("conflict", "insufficient_stock"),
				"INSUFFICIENT_STOCK", "available strong-local stock is below the requested quantity")
			return
		}
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return
	}
	a.m.Inc(MetricReservations)
	writeData(w, http.StatusCreated, res, nil)
}

func (a *API) transition(w http.ResponseWriter, r *http.Request, to string) {
	res, err := a.st.Transition(r.Context(), r.PathValue("id"), to, a.now())
	if err != nil {
		switch {
		case errors.Is(err, store.ErrNotFound):
			writeProblem(w, http.StatusNotFound, code("not_found", "reservation"), "reservation not found", r.PathValue("id"))
		case errors.Is(err, store.ErrBadState):
			writeProblem(w, http.StatusConflict, code("conflict", "state"), "illegal transition", err.Error())
		default:
			writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		}
		return
	}
	writeData(w, http.StatusOK, res, nil)
}

func (a *API) release(w http.ResponseWriter, r *http.Request) { a.transition(w, r, store.ResReleased) }
func (a *API) confirm(w http.ResponseWriter, r *http.Request) { a.transition(w, r, store.ResConsumed) }

// local is the reservation-critical read: strong-LOCAL records ONLY, never the rollup (R1).
func (a *API) local(w http.ResponseWriter, r *http.Request) {
	gpid, holder := r.URL.Query().Get("gpid"), r.URL.Query().Get("holder")
	if gpid == "" || holder == "" {
		writeProblem(w, http.StatusBadRequest, code("validation", "query"), "gpid and holder required", "")
		return
	}
	ls, err := a.st.Local(r.Context(), gpid, holder)
	if err != nil {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return
	}
	writeData(w, http.StatusOK, ls, nil)
}

// nilRollup is the eventual national view; every response carries asOf + lagMs (G11).
func (a *API) nilRollup(w http.ResponseWriter, r *http.Request) {
	at := a.now()
	roll, err := a.st.NIL(r.Context(), r.PathValue("gpid"), at)
	if err != nil {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return
	}
	writeData(w, http.StatusOK, roll, map[string]any{"asOf": at, "lagMs": roll.LagMs})
}
