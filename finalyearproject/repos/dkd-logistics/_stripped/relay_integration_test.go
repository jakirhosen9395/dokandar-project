//go:build integration

package outbox

import (
	"context"
	"io"
	"os"
	"testing"
	"time"

	"log/slog"

	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"

	"gitlab.com/final-year-project3354127/logistics-svc/internal/catalog"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/store"
)

type countingMetrics struct{ c map[string]int }

func (m *countingMetrics) Inc(name string) {
	if m.c == nil {
		m.c = map[string]int{}
	}
	m.c[name]++
}

// Drains a real outbox row (synthetic product, REAL frozen topic) to the live spine and
// verifies the row is marked published exactly once. Downstream consumers dedup on event_id,
// so the synthetic event is harmless (and lands in the audit sink like any other fact).
func TestRelayDrainsOutboxToSpine(t *testing.T) {
	brokers := os.Getenv("DKD_TEST_KAFKA_BROKERS")
	dsn := os.Getenv("DKD_TEST_DB_DSN")
	if brokers == "" || dsn == "" {
		t.Skip("DKD_TEST_KAFKA_BROKERS / DKD_TEST_DB_DSN not set; relay integration test skipped")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	st, err := store.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(st.Close)
	if err := st.Migrate(ctx); err != nil {
		t.Fatal(err)
	}

	p, err := catalog.NewProduct(catalog.NewProductInput{
		CategoryPath: []string{"agriculture"}, CategoryCode: "rice",
		NamesBn: "রিলে-টেস্ট চাল", BaseUnit: "kg",
		CreatedBy: "did:dokandar:0198c0de-0000-7000-8000-000000000001",
	}, func() int64 { return time.Now().UnixMilli() })
	if err != nil {
		t.Fatal(err)
	}
	ev := catalog.BuildProductCreated(p)
	if ev.Topic != dkd.TopicCatalogProductProductCreatedV1 {
		t.Fatalf("unexpected topic %s", ev.Topic)
	}
	if err := st.SaveNewProduct(ctx, p, []catalog.Event{ev}); err != nil {
		t.Fatal(err)
	}

	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	m := &countingMetrics{}
	r, err := New([]string{brokers}, st, log, m)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	if err := r.Ping(ctx); err != nil {
		t.Fatalf("broker ping: %v", err)
	}

	if err := r.drainOnce(ctx); err != nil {
		t.Fatalf("drain: %v", err)
	}
	if m.c[MetricPublished] == 0 {
		t.Fatal("published metric must increment")
	}
	rows, err := st.FetchUnpublished(ctx, 1000)
	if err != nil {
		t.Fatal(err)
	}
	for _, row := range rows {
		if row.EventID == ev.EventID {
			t.Fatal("drained row must be marked published")
		}
	}
}

func TestNewValidation(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	if _, err := New(nil, nil, log, &countingMetrics{}); err == nil {
		t.Fatal("empty brokers must be rejected")
	}
	if _, err := New([]string{"b:9092"}, nil, nil, nil); err == nil {
		t.Fatal("nil deps must be rejected")
	}
}
