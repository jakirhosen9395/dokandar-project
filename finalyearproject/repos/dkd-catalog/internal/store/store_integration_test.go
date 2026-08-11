//go:build integration

package store

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"testing"
	"time"

	"gitlab.com/final-year-project3354127/catalog-svc/internal/catalog"
)

func testStore(t *testing.T) *Store {
	t.Helper()
	dsn := os.Getenv("DKD_TEST_DB_DSN")
	if dsn == "" {
		t.Skip("DKD_TEST_DB_DSN not set; store integration test skipped")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	s, err := Open(ctx, dsn)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(s.Close)
	if err := s.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	if err := s.Migrate(ctx); err != nil { // idempotent
		t.Fatalf("second migrate: %v", err)
	}
	return s
}

func newProduct(t *testing.T) (*catalog.Product, []catalog.Event) {
	t.Helper()
	p, err := catalog.NewProduct(catalog.NewProductInput{
		CategoryPath: []string{"agriculture", "rice"}, CategoryCode: "rice",
		NamesBn: "চাল", NamesEn: "Rice", BaseUnit: "kg",
		Attributes: map[string]any{"grade": "A"},
		CreatedBy:  "did:dokandar:0198c0de-0000-7000-8000-000000000001",
	}, func() int64 { return time.Now().UnixMilli() })
	if err != nil {
		t.Fatal(err)
	}
	return p, []catalog.Event{catalog.BuildProductCreated(p)}
}

// R6 transactional outbox: aggregate + event land in one tx; the relay drains and marks published.
func TestSaveNewProductWritesOutboxAtomically(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	p, evs := newProduct(t)
	if err := s.SaveNewProduct(ctx, p, evs); err != nil {
		t.Fatal(err)
	}
	got, err := s.GetProduct(ctx, string(p.GPID))
	if err != nil {
		t.Fatal(err)
	}
	if got.NamesBn != p.NamesBn || got.Status != catalog.StatusDraft || got.Version != 1 {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
	rows, err := s.FetchUnpublished(ctx, 1000)
	if err != nil {
		t.Fatal(err)
	}
	var mine *OutboxRow
	for i := range rows {
		if rows[i].EventID == evs[0].EventID {
			mine = &rows[i]
		}
	}
	if mine == nil {
		t.Fatal("outbox row for the event not found")
	}
	var payload map[string]any
	if err := json.Unmarshal(mine.Payload, &payload); err != nil || payload["gpid"] != string(p.GPID) {
		t.Fatalf("outbox payload wrong: %v %s", err, mine.Payload)
	}
	if err := s.MarkPublished(ctx, []int64{mine.ID}); err != nil {
		t.Fatal(err)
	}
	rows, _ = s.FetchUnpublished(ctx, 1000)
	for _, r := range rows {
		if r.EventID == evs[0].EventID {
			t.Fatal("published row must not be re-fetched")
		}
	}
}

func TestUpdateProductOptimisticVersioning(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	p, evs := newProduct(t)
	if err := s.SaveNewProduct(ctx, p, evs); err != nil {
		t.Fatal(err)
	}
	prev := p.Version
	if err := p.Publish(p.CreatedBy, func() int64 { return time.Now().UnixMilli() }); err != nil {
		t.Fatal(err)
	}
	ev := catalog.BuildProductPublished(p, p.CreatedBy, p.UpdatedAtMs)
	if err := s.UpdateProduct(ctx, p, prev, []catalog.Event{ev}); err != nil {
		t.Fatal(err)
	}
	// stale prev version must conflict
	if err := s.UpdateProduct(ctx, p, prev, nil); !errors.Is(err, ErrVersionConflict) {
		t.Fatalf("want ErrVersionConflict, got %v", err)
	}
	got, _ := s.GetProduct(ctx, string(p.GPID))
	if got.Status != catalog.StatusPublished {
		t.Fatal("status not persisted")
	}
}

func TestGetProductNotFound(t *testing.T) {
	s := testStore(t)
	if _, err := s.GetProduct(context.Background(), "GP-none-0198c0de-0000-7000-8000-00000000dead"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
}

func TestInboxDedup(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	id := "it-" + time.Now().UTC().Format("150405.000000000")
	dup, err := s.InboxSeen(ctx, id)
	if err != nil || dup {
		t.Fatalf("first sighting must not be dup: %v %v", dup, err)
	}
	dup, err = s.InboxSeen(ctx, id)
	if err != nil || !dup {
		t.Fatalf("second sighting must be dup: %v %v", dup, err)
	}
}

func TestPassportDeltaProjection(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	p, _ := newProduct(t)
	g := string(p.GPID)
	if err := s.ApplyPassportDelta(ctx, g, 2); err != nil {
		t.Fatal(err)
	}
	if err := s.ApplyPassportDelta(ctx, g, -1); err != nil {
		t.Fatal(err)
	}
	n, err := s.ActivePassportCount(ctx, g)
	if err != nil || n != 1 {
		t.Fatalf("count=%d err=%v want 1", n, err)
	}
	if n, _ := s.ActivePassportCount(ctx, "GP-none-0198c0de-0000-7000-8000-00000000beef"); n != 0 {
		t.Fatal("unknown gpid must count 0")
	}
}

func TestIdempotencyRoundTrip(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	key := "idem-" + time.Now().UTC().Format("150405.000000000")
	if err := s.PutIdem(ctx, key, "hash1", 201, []byte(`{"ok":true}`)); err != nil {
		t.Fatal(err)
	}
	status, hash, resp, found, err := s.GetIdem(ctx, key)
	if err != nil || !found || status != 201 || hash != "hash1" {
		t.Fatalf("idem round-trip: %d %s %s %v %v", status, hash, resp, found, err)
	}
	var body map[string]any // JSONB normalizes whitespace — compare semantically
	if err := json.Unmarshal(resp, &body); err != nil || body["ok"] != true {
		t.Fatalf("idem response payload: %s (%v)", resp, err)
	}
	_, _, _, found, _ = s.GetIdem(ctx, key+"-absent")
	if found {
		t.Fatal("absent key must not be found")
	}
}

// HIGH-1 review fix: the deprecation update re-checks the passport count under a row lock.
func TestUpdateProductDeprecatingGuard(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	p, evs := newProduct(t)
	if err := s.SaveNewProduct(ctx, p, evs); err != nil {
		t.Fatal(err)
	}
	nowFn := func() int64 { return time.Now().UnixMilli() }
	_ = p.Publish(p.CreatedBy, nowFn)
	if err := s.UpdateProduct(ctx, p, 1, nil); err != nil {
		t.Fatal(err)
	}
	// active passports present -> guarded even though the caller's pre-check was stale
	if err := s.ApplyPassportDelta(ctx, string(p.GPID), 2); err != nil {
		t.Fatal(err)
	}
	prev := p.Version
	if err := p.Deprecate("", "r", p.CreatedBy, 0 /* stale caller view */, nowFn); err != nil {
		t.Fatal(err)
	}
	if err := s.UpdateProductDeprecating(ctx, p, prev, nil); !errors.Is(err, ErrActivePassports) {
		t.Fatalf("want ErrActivePassports, got %v", err)
	}
	// drain the passports -> deprecation proceeds
	if err := s.ApplyPassportDelta(ctx, string(p.GPID), -2); err != nil {
		t.Fatal(err)
	}
	if err := s.UpdateProductDeprecating(ctx, p, prev, nil); err != nil {
		t.Fatalf("deprecate with zero passports: %v", err)
	}
}

// HIGH-3 review fix: inbox row + count delta commit atomically and dedup on replay.
func TestApplyPassportDeltaOnce(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	p, _ := newProduct(t)
	id := "once-" + time.Now().UTC().Format("150405.000000000")
	dup, err := s.ApplyPassportDeltaOnce(ctx, id, string(p.GPID), 1)
	if err != nil || dup {
		t.Fatalf("first apply: dup=%v err=%v", dup, err)
	}
	dup, err = s.ApplyPassportDeltaOnce(ctx, id, string(p.GPID), 1)
	if err != nil || !dup {
		t.Fatalf("replay must dedup: dup=%v err=%v", dup, err)
	}
	if n, _ := s.ActivePassportCount(ctx, string(p.GPID)); n != 1 {
		t.Fatalf("count must be exactly 1, got %d", n)
	}
}

func TestListProductsKeysetCursor(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	for i := 0; i < 3; i++ {
		p, evs := newProduct(t)
		if err := s.SaveNewProduct(ctx, p, evs); err != nil {
			t.Fatal(err)
		}
	}
	page1, err := s.ListProducts(ctx, "", 2)
	if err != nil || len(page1) != 2 {
		t.Fatalf("page1: %d %v", len(page1), err)
	}
	page2, err := s.ListProducts(ctx, string(page1[1].GPID), 200)
	if err != nil || len(page2) == 0 {
		t.Fatalf("page2: %d %v", len(page2), err)
	}
	if string(page2[0].GPID) <= string(page1[1].GPID) {
		t.Fatal("cursor must advance strictly")
	}
}
