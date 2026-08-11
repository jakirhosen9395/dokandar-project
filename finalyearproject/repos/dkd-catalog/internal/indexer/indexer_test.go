package indexer

import (
	"context"
	"errors"
	"io"
	"testing"

	"log/slog"

	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"

	"gitlab.com/final-year-project3354127/catalog-svc/internal/catalog"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/consumer"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/store"
)

type fakeStore struct {
	products map[string]*catalog.Product
	err      error
}

func (f *fakeStore) GetProduct(_ context.Context, gpid string) (*catalog.Product, error) {
	if f.err != nil {
		return nil, f.err
	}
	p, ok := f.products[gpid]
	if !ok {
		return nil, store.ErrNotFound
	}
	return p, nil
}

type fakeSearch struct {
	docs map[string]map[string]any
	err  error
}

func (f *fakeSearch) IndexProduct(_ context.Context, gpid string, doc map[string]any) error {
	if f.err != nil {
		return f.err
	}
	if f.docs == nil {
		f.docs = map[string]map[string]any{}
	}
	f.docs[gpid] = doc
	return nil
}

type fakeMetrics struct{ c map[string]int }

func (m *fakeMetrics) Inc(name string) {
	if m.c == nil {
		m.c = map[string]int{}
	}
	m.c[name]++
}

func seed(t *testing.T) (*fakeStore, *catalog.Product) {
	t.Helper()
	p, err := catalog.NewProduct(catalog.NewProductInput{
		CategoryPath: []string{"agriculture"}, CategoryCode: "rice",
		NamesBn: "চাল", BaseUnit: "kg",
		CreatedBy: "did:dokandar:0198c0de-0000-7000-8000-000000000001",
	}, func() int64 { return 1719900000000 })
	if err != nil {
		t.Fatal(err)
	}
	return &fakeStore{products: map[string]*catalog.Product{string(p.GPID): p}}, p
}

func newIx(st Store, se Search, m Metrics) *Indexer {
	return New(st, se, m, slog.New(slog.NewTextHandler(io.Discard, nil)))
}

func TestHandleUpsertsDocKeyedByGPID(t *testing.T) {
	st, p := seed(t)
	se, m := &fakeSearch{}, &fakeMetrics{}
	ev := consumer.RawEvent{Topic: dkd.TopicCatalogProductProductPublishedV1,
		EventID: "e1", Value: []byte(`{"gpid":"` + string(p.GPID) + `"}`)}
	if err := newIx(st, se, m).Handle(context.Background(), ev); err != nil {
		t.Fatal(err)
	}
	doc := se.docs[string(p.GPID)]
	if doc == nil || doc["namesBn"] != "চাল" || doc["status"] != "DRAFT" {
		t.Fatalf("doc: %v", doc)
	}
	if m.c[MetricIndexed] != 1 {
		t.Fatal("indexed metric")
	}
}

func TestHandleSkipsBadPayloadAndUnknownGPID(t *testing.T) {
	st, _ := seed(t)
	se, m := &fakeSearch{}, &fakeMetrics{}
	ix := newIx(st, se, m)
	if err := ix.Handle(context.Background(), consumer.RawEvent{EventID: "e2", Value: []byte(`junk`)}); err != nil {
		t.Fatal("bad payload must be skipped, not failed")
	}
	absent := consumer.RawEvent{EventID: "e3", Value: []byte(`{"gpid":"GP-none-0198c0de-0000-7000-8000-00000000dead"}`)}
	if err := ix.Handle(context.Background(), absent); err != nil {
		t.Fatal("unknown gpid must be skipped, not failed")
	}
	if m.c[MetricSkipped] != 2 {
		t.Fatalf("skipped metric: %d", m.c[MetricSkipped])
	}
}

func TestHandlePropagatesInfraErrors(t *testing.T) {
	st, p := seed(t)
	ev := consumer.RawEvent{EventID: "e4", Value: []byte(`{"gpid":"` + string(p.GPID) + `"}`)}
	st.err = errors.New("db down")
	if err := newIx(st, &fakeSearch{}, &fakeMetrics{}).Handle(context.Background(), ev); err == nil {
		t.Fatal("store error must propagate (park/replay)")
	}
	st.err = nil
	if err := newIx(st, &fakeSearch{err: errors.New("os down")}, &fakeMetrics{}).Handle(context.Background(), ev); err == nil {
		t.Fatal("search error must propagate (park/replay)")
	}
}

func TestParkAcknowledges(t *testing.T) {
	m := &fakeMetrics{}
	if ok := newIx(&fakeStore{}, &fakeSearch{}, m).Park(consumer.RawEvent{EventID: "e5"}, errors.New("x")); !ok {
		t.Fatal("park must ack (index rebuildable)")
	}
	if m.c[MetricParked] != 1 {
		t.Fatal("parked metric")
	}
}

func TestTopicsAreTheIndexFeed(t *testing.T) {
	ts := Topics()
	if len(ts) != 4 || ts[0] != dkd.TopicCatalogProductProductPublishedV1 {
		t.Fatalf("topics: %v", ts)
	}
}
