package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"log/slog"

	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"

	"gitlab.com/final-year-project3354127/catalog-svc/internal/catalog"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/store"
)

const actor = "did:dokandar:0198c0de-0000-7000-8000-000000000001"

type idemRec struct {
	hash   string
	status int
	resp   []byte
}

type fakeStore struct {
	products map[string]*catalog.Product
	events   []catalog.Event
	idem     map[string]idemRec
	active   map[string]int64
}

func newFake() *fakeStore {
	return &fakeStore{products: map[string]*catalog.Product{}, idem: map[string]idemRec{}, active: map[string]int64{}}
}

func (f *fakeStore) SaveNewProduct(_ context.Context, p *catalog.Product, evs []catalog.Event) error {
	f.products[string(p.GPID)] = p
	f.events = append(f.events, evs...)
	return nil
}
func (f *fakeStore) UpdateProduct(_ context.Context, p *catalog.Product, _ int64, evs []catalog.Event) error {
	f.products[string(p.GPID)] = p
	f.events = append(f.events, evs...)
	return nil
}
func (f *fakeStore) UpdateProductDeprecating(ctx context.Context, p *catalog.Product, prev int64, evs []catalog.Event) error {
	if f.active[string(p.GPID)] > 0 {
		return store.ErrActivePassports
	}
	return f.UpdateProduct(ctx, p, prev, evs)
}
func (f *fakeStore) GetProduct(_ context.Context, gpid string) (*catalog.Product, error) {
	p, ok := f.products[gpid]
	if !ok {
		return nil, store.ErrNotFound
	}
	return p, nil
}
func (f *fakeStore) ListProducts(_ context.Context, after string, limit int) ([]*catalog.Product, error) {
	var out []*catalog.Product
	for _, p := range f.products {
		out = append(out, p)
		if len(out) == limit {
			break
		}
	}
	return out, nil
}
func (f *fakeStore) ActivePassportCount(_ context.Context, gpid string) (int64, error) {
	return f.active[gpid], nil
}
func (f *fakeStore) GetIdem(_ context.Context, key string) (int, string, []byte, bool, error) {
	r, ok := f.idem[key]
	if !ok {
		return 0, "", nil, false, nil
	}
	return r.status, r.hash, r.resp, true, nil
}
func (f *fakeStore) PutIdem(_ context.Context, key, hash string, status int, resp []byte) error {
	f.idem[key] = idemRec{hash: hash, status: status, resp: resp}
	return nil
}

type fakeSearch struct {
	enabled bool
	docs    []map[string]any
}

func (f *fakeSearch) Enabled() bool { return f.enabled }
func (f *fakeSearch) Search(context.Context, string, int) ([]map[string]any, error) {
	return f.docs, nil
}

type fakeMetrics struct{ c map[string]int }

func (m *fakeMetrics) Inc(name string) {
	if m.c == nil {
		m.c = map[string]int{}
	}
	m.c[name]++
}

func testAPI(f *fakeStore, se Searcher) http.Handler {
	a := New(f, se, &fakeMetrics{}, slog.New(slog.NewTextHandler(io.Discard, nil)),
		func() int64 { return 1719900000000 })
	mux := http.NewServeMux()
	a.Register(mux)
	return mux
}

func doReq(t *testing.T, h http.Handler, method, path, idemKey, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if idemKey != "" {
		req.Header.Set("Idempotency-Key", idemKey)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	return w
}

const createBody = `{"categoryPath":["agriculture","rice"],"categoryCode":"rice","namesBn":"চাল","baseUnit":"kg","createdBy":"` + actor + `"}`

func TestCreateRequiresIdempotencyKey(t *testing.T) {
	w := doReq(t, testAPI(newFake(), nil), http.MethodPost, "/v1/catalog/products", "", createBody)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status %d", w.Code)
	}
	if ct := w.Header().Get("Content-Type"); ct != "application/problem+json" {
		t.Fatalf("content-type %s", ct)
	}
	if !bytes.Contains(w.Body.Bytes(), []byte("idempotency_key_required")) {
		t.Fatalf("problem code missing: %s", w.Body.String())
	}
}

func TestCreateProduct(t *testing.T) {
	f := newFake()
	w := doReq(t, testAPI(f, nil), http.MethodPost, "/v1/catalog/products", "k1", createBody)
	if w.Code != http.StatusCreated {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	var env struct {
		Success bool `json:"success"`
		Data    struct {
			GPID   string `json:"gpid"`
			Status string `json:"status"`
		} `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &env); err != nil || !env.Success {
		t.Fatalf("envelope: %v %s", err, w.Body.String())
	}
	if !strings.HasPrefix(env.Data.GPID, "GP-rice-") || env.Data.Status != "DRAFT" {
		t.Fatalf("data: %+v", env.Data)
	}
	if len(f.events) != 1 || f.events[0].Topic != dkd.TopicCatalogProductProductCreatedV1 {
		t.Fatalf("events: %+v", f.events)
	}
}

func TestIdempotentReplay(t *testing.T) {
	f := newFake()
	h := testAPI(f, nil)
	first := doReq(t, h, http.MethodPost, "/v1/catalog/products", "same-key", createBody)
	if first.Code != http.StatusCreated {
		t.Fatal(first.Body.String())
	}
	second := doReq(t, h, http.MethodPost, "/v1/catalog/products", "same-key", createBody)
	if second.Code != http.StatusCreated {
		t.Fatalf("replay status %d", second.Code)
	}
	if second.Header().Get("Idempotency-Replay") != "true" {
		t.Fatal("replay header missing")
	}
	if second.Body.String() != first.Body.String() {
		t.Fatal("replay must return the stored response body")
	}
	if len(f.products) != 1 {
		t.Fatalf("replay must not create a second product: %d", len(f.products))
	}
}

func TestIdempotencyKeyReuseDifferentBody(t *testing.T) {
	h := testAPI(newFake(), nil)
	_ = doReq(t, h, http.MethodPost, "/v1/catalog/products", "k2", createBody)
	w := doReq(t, h, http.MethodPost, "/v1/catalog/products", "k2", strings.Replace(createBody, "rice", "jute", 1))
	if w.Code != http.StatusConflict {
		t.Fatalf("status %d", w.Code)
	}
}

func seedProduct(t *testing.T, f *fakeStore) *catalog.Product {
	t.Helper()
	p, err := catalog.NewProduct(catalog.NewProductInput{
		CategoryPath: []string{"agriculture"}, CategoryCode: "rice",
		NamesBn: "চাল", BaseUnit: "kg", CreatedBy: actor,
	}, func() int64 { return 1719900000000 })
	if err != nil {
		t.Fatal(err)
	}
	f.products[string(p.GPID)] = p
	return p
}

func TestLifecyclePublish(t *testing.T) {
	f := newFake()
	p := seedProduct(t, f)
	w := doReq(t, testAPI(f, nil), http.MethodPatch,
		"/v1/catalog/products/"+string(p.GPID)+"/lifecycle", "k3",
		`{"action":"publish","actor":"`+actor+`"}`)
	if w.Code != http.StatusOK {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	if p.Status != catalog.StatusPublished {
		t.Fatal("product not published")
	}
	last := f.events[len(f.events)-1]
	if last.Topic != dkd.TopicCatalogProductProductPublishedV1 {
		t.Fatalf("event topic %s", last.Topic)
	}
}

func TestDeprecateBlockedByActivePassports(t *testing.T) {
	f := newFake()
	p := seedProduct(t, f)
	_ = p.Publish(actor, func() int64 { return 1719900000001 })
	f.active[string(p.GPID)] = 3 // M5 projection says passports still reference the GPID
	w := doReq(t, testAPI(f, nil), http.MethodPatch,
		"/v1/catalog/products/"+string(p.GPID)+"/lifecycle", "k4",
		`{"action":"deprecate","reason":"superseded","actor":"`+actor+`"}`)
	if w.Code != http.StatusConflict {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
}

func TestGetProductNotFound(t *testing.T) {
	w := doReq(t, testAPI(newFake(), nil), http.MethodGet,
		"/v1/catalog/products/GP-rice-0198c0de-0000-7000-8000-000000000099", "", "")
	if w.Code != http.StatusNotFound {
		t.Fatalf("status %d", w.Code)
	}
	if ct := w.Header().Get("Content-Type"); ct != "application/problem+json" {
		t.Fatalf("content-type %s", ct)
	}
}

func TestSearchDisabled(t *testing.T) {
	w := doReq(t, testAPI(newFake(), &fakeSearch{enabled: false}), http.MethodGet, "/v1/catalog/search?q=rice", "", "")
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("status %d", w.Code)
	}
}

func TestSearchEnabled(t *testing.T) {
	se := &fakeSearch{enabled: true, docs: []map[string]any{{"gpid": "GP-rice-x", "namesBn": "চাল"}}}
	w := doReq(t, testAPI(newFake(), se), http.MethodGet, "/v1/catalog/search?q=চাল", "", "")
	if w.Code != http.StatusOK {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	if !bytes.Contains(w.Body.Bytes(), []byte("GP-rice-x")) {
		t.Fatal("docs missing from response")
	}
}

func TestListCursorMeta(t *testing.T) {
	f := newFake()
	seedProduct(t, f)
	seedProduct(t, f)
	w := doReq(t, testAPI(f, nil), http.MethodGet, "/v1/catalog/products?limit=2", "", "")
	if w.Code != http.StatusOK {
		t.Fatalf("status %d", w.Code)
	}
	var env struct {
		Meta struct {
			Page struct {
				NextCursor string `json:"nextCursor"`
				HasMore    bool   `json:"hasMore"`
			} `json:"page"`
		} `json:"meta"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &env)
	if !env.Meta.Page.HasMore || env.Meta.Page.NextCursor == "" {
		t.Fatalf("cursor meta: %+v", env.Meta.Page)
	}
}
