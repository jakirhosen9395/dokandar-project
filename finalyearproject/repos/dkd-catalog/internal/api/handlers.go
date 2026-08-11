// Package api exposes catalog-svc's external REST /v1 surface (via the gateway):
// {success,data,error,meta} envelope, RFC-7807 problem+json (dokandar.catalog.* taxonomy,
// concrete codes provisional pending error-codes.yaml), Idempotency-Key on every unsafe write,
// cursor-only pagination. Route shapes follow SA §5.5 (rest_apis are NEEDS-INFO in api-registry).
package api

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"

	"log/slog"

	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"

	"gitlab.com/final-year-project3354127/catalog-svc/internal/catalog"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/security"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/store"
)

const (
	MetricCommands = "catalog_commands_total"
	MetricReplays  = "catalog_idempotent_replays_total"

	maxBodyBytes = 1 << 20 // 1 MiB
)

type Store interface {
	SaveNewProduct(ctx context.Context, p *catalog.Product, evs []catalog.Event) error
	UpdateProduct(ctx context.Context, p *catalog.Product, prevVersion int64, evs []catalog.Event) error
	GetProduct(ctx context.Context, gpid string) (*catalog.Product, error)
	ListProducts(ctx context.Context, afterGpid string, limit int) ([]*catalog.Product, error)
	ActivePassportCount(ctx context.Context, gpid string) (int64, error)
	GetIdem(ctx context.Context, key string) (int, string, []byte, bool, error)
	PutIdem(ctx context.Context, key, reqHash string, status int, resp []byte) error
	// UpdateProductDeprecating re-checks the M5 passport count under a row lock inside the
	// update transaction (TOCTOU fix); returns store.ErrActivePassports when guarded.
	UpdateProductDeprecating(ctx context.Context, p *catalog.Product, prevVersion int64, evs []catalog.Event) error
}

type Searcher interface {
	Enabled() bool
	Search(ctx context.Context, q string, limit int) ([]map[string]any, error)
}

type Metrics interface{ Inc(name string) }

type API struct {
	st  Store
	se  Searcher
	m   Metrics
	log *slog.Logger
	now catalog.NowFunc
}

func New(st Store, se Searcher, m Metrics, log *slog.Logger, now catalog.NowFunc) *API {
	return &API{st: st, se: se, m: m, log: log, now: now}
}

func (a *API) Register(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/catalog/products", a.idem(a.createProduct))
	mux.HandleFunc("GET /v1/catalog/products/{gpid}", a.getProduct)
	mux.HandleFunc("GET /v1/catalog/products", a.listProducts)
	mux.HandleFunc("PATCH /v1/catalog/products/{gpid}/lifecycle", a.idem(a.lifecycle))
	mux.HandleFunc("PATCH /v1/catalog/products/{gpid}", a.idem(a.updateMasterData))
	mux.HandleFunc("POST /v1/catalog/products/{gpid}/price-rules", a.idem(a.addPriceRule))
	mux.HandleFunc("GET /v1/catalog/search", a.search)
}

// ---- envelope + problem helpers -------------------------------------------------------------

func code(category, reason string) string {
	c, err := dkd.ErrorCode("catalog", category, reason)
	if err != nil {
		return "dokandar.catalog.internal.bad_code"
	}
	return c
}

func writeJSON(w http.ResponseWriter, status int, contentType string, body any) {
	w.Header().Set("Content-Type", contentType)
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
		"type": "about:blank", "title": title, "status": status,
		"code": codeStr, "detail": detail,
	})
}

// ---- actor resolution ------------------------------------------------------------------------

// actorDID prefers the authenticated JWT subject; dev/back-office calls may carry an explicit
// actor DID in the body until the edge tier owns authentication end-to-end.
func actorDID(r *http.Request, bodyActor string) (string, error) {
	if c := security.ClaimsFrom(r.Context()); c != nil && c.Sub != "" {
		if _, err := dkd.NewDID(c.Sub); err == nil {
			return c.Sub, nil
		}
	}
	if bodyActor != "" {
		if _, err := dkd.NewDID(bodyActor); err != nil {
			return "", fmt.Errorf("invalid actor DID")
		}
		return bodyActor, nil
	}
	return "", fmt.Errorf("actor DID required (JWT sub or explicit field)")
}

// ---- idempotency wrapper ---------------------------------------------------------------------

type recorder struct {
	http.ResponseWriter
	status int
	buf    bytes.Buffer
}

func (r *recorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

func (r *recorder) Write(b []byte) (int, error) {
	r.buf.Write(b)
	return r.ResponseWriter.Write(b)
}

// idem enforces the mandatory Idempotency-Key contract on unsafe writes: same key + same body
// replays the stored response; same key + different body is a conflict; 5xx is never stored.
func (a *API) idem(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		key := r.Header.Get("Idempotency-Key")
		if key == "" {
			writeProblem(w, http.StatusBadRequest, code("validation", "idempotency_key_required"),
				"Idempotency-Key required", "unsafe writes must carry an Idempotency-Key header")
			return
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, maxBodyBytes))
		if err != nil {
			writeProblem(w, http.StatusBadRequest, code("validation", "unreadable_body"),
				"unreadable body", err.Error())
			return
		}
		r.Body = io.NopCloser(bytes.NewReader(body))
		sum := sha256.Sum256(body)
		hash := hex.EncodeToString(sum[:])

		status, storedHash, resp, found, err := a.st.GetIdem(r.Context(), key)
		if err != nil {
			writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "idempotency_store"),
				"idempotency store unavailable", err.Error())
			return
		}
		if found {
			if storedHash != hash {
				writeProblem(w, http.StatusConflict, code("conflict", "idempotency_key_reused"),
					"Idempotency-Key reused", "the key was used with a different request body")
				return
			}
			a.m.Inc(MetricReplays)
			w.Header().Set("Idempotency-Replay", "true")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(status)
			_, _ = w.Write(resp)
			return
		}
		rec := &recorder{ResponseWriter: w, status: http.StatusOK}
		next(rec, r)
		if rec.status < 500 {
			if err := a.st.PutIdem(r.Context(), key, hash, rec.status, rec.buf.Bytes()); err != nil {
				a.log.Warn("idempotency record failed", "err", err)
			}
		}
	}
}

// ---- handlers ---------------------------------------------------------------------------------

type createReq struct {
	CategoryPath []string       `json:"categoryPath"`
	CategoryCode string         `json:"categoryCode"`
	NamesBn      string         `json:"namesBn"`
	NamesEn      string         `json:"namesEn"`
	BaseUnit     string         `json:"baseUnit"`
	Attributes   map[string]any `json:"attributes"`
	CreatedBy    string         `json:"createdBy"`
}

func (a *API) createProduct(w http.ResponseWriter, r *http.Request) {
	var req createReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeProblem(w, http.StatusBadRequest, code("validation", "invalid_json"), "invalid JSON", err.Error())
		return
	}
	actor, err := actorDID(r, req.CreatedBy)
	if err != nil {
		writeProblem(w, http.StatusBadRequest, code("validation", "actor_did"), "invalid actor", err.Error())
		return
	}
	p, err := catalog.NewProduct(catalog.NewProductInput{
		CategoryPath: req.CategoryPath, CategoryCode: req.CategoryCode,
		NamesBn: req.NamesBn, NamesEn: req.NamesEn, BaseUnit: req.BaseUnit,
		Attributes: req.Attributes, CreatedBy: actor,
	}, a.now)
	if err != nil {
		writeProblem(w, http.StatusBadRequest, code("validation", "invalid_product"), "invalid product", err.Error())
		return
	}
	if err := a.st.SaveNewProduct(r.Context(), p, []catalog.Event{catalog.BuildProductCreated(p)}); err != nil {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return
	}
	a.m.Inc(MetricCommands)
	writeData(w, http.StatusCreated, p, nil)
}

func (a *API) getProduct(w http.ResponseWriter, r *http.Request) {
	p, err := a.st.GetProduct(r.Context(), r.PathValue("gpid"))
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeProblem(w, http.StatusNotFound, code("not_found", "product"), "product not found", r.PathValue("gpid"))
			return
		}
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return
	}
	writeData(w, http.StatusOK, p, nil)
}

func (a *API) listProducts(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	cursor := r.URL.Query().Get("cursor")
	items, err := a.st.ListProducts(r.Context(), cursor, limit)
	if err != nil {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return
	}
	next, hasMore := "", false
	if len(items) == limit {
		next, hasMore = string(items[len(items)-1].GPID), true
	}
	writeData(w, http.StatusOK, items, map[string]any{
		"page": map[string]any{"nextCursor": next, "hasMore": hasMore, "limit": limit},
	})
}

type lifecycleReq struct {
	Action        string `json:"action"` // publish | deprecate
	SuccessorGpid string `json:"successorGpid"`
	Reason        string `json:"reason"`
	Actor         string `json:"actor"`
}

func (a *API) lifecycle(w http.ResponseWriter, r *http.Request) {
	gpid := r.PathValue("gpid")
	var req lifecycleReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeProblem(w, http.StatusBadRequest, code("validation", "invalid_json"), "invalid JSON", err.Error())
		return
	}
	actor, err := actorDID(r, req.Actor)
	if err != nil {
		writeProblem(w, http.StatusBadRequest, code("validation", "actor_did"), "invalid actor", err.Error())
		return
	}
	p, err := a.st.GetProduct(r.Context(), gpid)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeProblem(w, http.StatusNotFound, code("not_found", "product"), "product not found", gpid)
			return
		}
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return
	}
	prev := p.Version
	var evs []catalog.Event
	switch req.Action {
	case "publish":
		if err := p.Publish(actor, a.now); err != nil {
			writeProblem(w, http.StatusConflict, code("conflict", "lifecycle"), "lifecycle violation", err.Error())
			return
		}
		evs = []catalog.Event{catalog.BuildProductPublished(p, actor, p.UpdatedAtMs)}
	case "deprecate":
		active, err := a.st.ActivePassportCount(r.Context(), gpid)
		if err != nil {
			writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
			return
		}
		if err := p.Deprecate(req.SuccessorGpid, req.Reason, actor, active, a.now); err != nil {
			writeProblem(w, http.StatusConflict, code("conflict", "lifecycle"), "lifecycle violation", err.Error())
			return
		}
		evs = []catalog.Event{catalog.BuildProductDeprecated(p, req.SuccessorGpid, req.Reason, actor, p.UpdatedAtMs)}
	default:
		writeProblem(w, http.StatusBadRequest, code("validation", "unknown_action"),
			"unknown lifecycle action", "supported: publish, deprecate")
		return
	}
	update := a.st.UpdateProduct
	if req.Action == "deprecate" {
		update = a.st.UpdateProductDeprecating // M5 re-check under row lock (TOCTOU fix)
	}
	if err := update(r.Context(), p, prev, evs); err != nil {
		switch {
		case errors.Is(err, store.ErrVersionConflict):
			writeProblem(w, http.StatusConflict, code("conflict", "version"), "concurrent update", "retry with fresh state")
		case errors.Is(err, store.ErrActivePassports):
			writeProblem(w, http.StatusConflict, code("conflict", "lifecycle"), "lifecycle violation",
				"active custody passports reference this gpid (M5)")
		default:
			writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		}
		return
	}
	a.m.Inc(MetricCommands)
	writeData(w, http.StatusOK, p, nil)
}

type masterDataReq struct {
	Changes map[string]any `json:"changes"`
	Actor   string         `json:"actor"`
}

func (a *API) updateMasterData(w http.ResponseWriter, r *http.Request) {
	gpid := r.PathValue("gpid")
	var req masterDataReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeProblem(w, http.StatusBadRequest, code("validation", "invalid_json"), "invalid JSON", err.Error())
		return
	}
	actor, err := actorDID(r, req.Actor)
	if err != nil {
		writeProblem(w, http.StatusBadRequest, code("validation", "actor_did"), "invalid actor", err.Error())
		return
	}
	p, err := a.st.GetProduct(r.Context(), gpid)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeProblem(w, http.StatusNotFound, code("not_found", "product"), "product not found", gpid)
			return
		}
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return
	}
	prev := p.Version
	fields, err := p.UpdateMasterData(req.Changes, actor, a.now)
	if err != nil {
		writeProblem(w, http.StatusConflict, code("conflict", "master_data"), "master-data violation", err.Error())
		return
	}
	ev := catalog.BuildProductMasterDataUpdated(p, fields, actor, p.UpdatedAtMs)
	if err := a.st.UpdateProduct(r.Context(), p, prev, []catalog.Event{ev}); err != nil {
		if errors.Is(err, store.ErrVersionConflict) {
			writeProblem(w, http.StatusConflict, code("conflict", "version"), "concurrent update", "retry with fresh state")
			return
		}
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return
	}
	a.m.Inc(MetricCommands)
	writeData(w, http.StatusOK, p, nil)
}

type priceRuleReq struct {
	TierApplicable  string `json:"tierApplicable"`
	BasePricePoisha int64  `json:"basePricePoisha"`
	ValidFrom       int64  `json:"validFrom"`
	ValidUntil      int64  `json:"validUntil"`
	Actor           string `json:"actor"`
}

func (a *API) addPriceRule(w http.ResponseWriter, r *http.Request) {
	gpid := r.PathValue("gpid")
	var req priceRuleReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeProblem(w, http.StatusBadRequest, code("validation", "invalid_json"), "invalid JSON", err.Error())
		return
	}
	actor, err := actorDID(r, req.Actor)
	if err != nil {
		writeProblem(w, http.StatusBadRequest, code("validation", "actor_did"), "invalid actor", err.Error())
		return
	}
	p, err := a.st.GetProduct(r.Context(), gpid)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeProblem(w, http.StatusNotFound, code("not_found", "product"), "product not found", gpid)
			return
		}
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return
	}
	prev := p.Version
	rule, err := p.AddPriceRule(catalog.PriceRule{
		TierApplicable: req.TierApplicable, BasePricePoisha: req.BasePricePoisha,
		ValidFromMs: req.ValidFrom, ValidUntilMs: req.ValidUntil,
	}, a.now)
	if err != nil {
		writeProblem(w, http.StatusConflict, code("conflict", "price_rule"), "price rule rejected", err.Error())
		return
	}
	ev := catalog.BuildProductPriceRuleAdded(p, rule, actor, p.UpdatedAtMs)
	if err := a.st.UpdateProduct(r.Context(), p, prev, []catalog.Event{ev}); err != nil {
		if errors.Is(err, store.ErrVersionConflict) {
			writeProblem(w, http.StatusConflict, code("conflict", "version"), "concurrent update", "retry with fresh state")
			return
		}
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return
	}
	a.m.Inc(MetricCommands)
	writeData(w, http.StatusCreated, rule, nil)
}

func (a *API) search(w http.ResponseWriter, r *http.Request) {
	if a.se == nil || !a.se.Enabled() {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "search_disabled"),
			"search unavailable", "no OpenSearch backend configured")
		return
	}
	q := r.URL.Query().Get("q")
	if q == "" {
		writeProblem(w, http.StatusBadRequest, code("validation", "query_required"), "q required", "supply ?q=")
		return
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	docs, err := a.se.Search(r.Context(), q, limit)
	if err != nil {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "search"), "search failure", err.Error())
		return
	}
	writeData(w, http.StatusOK, docs, map[string]any{"page": map[string]any{"limit": limit, "hasMore": false, "nextCursor": ""}})
}
