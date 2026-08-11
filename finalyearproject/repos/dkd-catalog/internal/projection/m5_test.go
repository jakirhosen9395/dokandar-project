package projection

import (
	"context"
	"errors"
	"io"
	"testing"

	"log/slog"

	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"

	"gitlab.com/final-year-project3354127/catalog-svc/internal/consumer"
)

type fakeStore struct {
	seen   map[string]bool
	deltas map[string]int64
	err    error
}

func (f *fakeStore) InboxSeen(_ context.Context, id string) (bool, error) {
	if f.err != nil {
		return false, f.err
	}
	if f.seen == nil {
		f.seen = map[string]bool{}
	}
	dup := f.seen[id]
	f.seen[id] = true
	return dup, nil
}
func (f *fakeStore) ApplyPassportDeltaOnce(_ context.Context, id, gpid string, d int64) (bool, error) {
	if f.err != nil {
		return false, f.err
	}
	if f.seen == nil {
		f.seen = map[string]bool{}
	}
	if f.seen[id] {
		return true, nil
	}
	f.seen[id] = true
	if f.deltas == nil {
		f.deltas = map[string]int64{}
	}
	f.deltas[gpid] += d
	return false, nil
}

type fakeMetrics struct{ c map[string]int }

func (m *fakeMetrics) Inc(name string) {
	if m.c == nil {
		m.c = map[string]int{}
	}
	m.c[name]++
}

func newM5(f *fakeStore, m *fakeMetrics) *M5 {
	return New(f, m, slog.New(slog.NewTextHandler(io.Discard, nil)))
}

func TestCustodyInitializedIncrementsCount(t *testing.T) {
	f, m := &fakeStore{}, &fakeMetrics{}
	ev := consumer.RawEvent{Topic: dkd.TopicCustodyPassportCustodyInitializedV1,
		EventID: "e1", Value: []byte(`{"gpid":"GP-rice-0198c0de-0000-7000-8000-000000000001"}`)}
	if err := newM5(f, m).Handle(context.Background(), ev); err != nil {
		t.Fatal(err)
	}
	if f.deltas["GP-rice-0198c0de-0000-7000-8000-000000000001"] != 1 {
		t.Fatalf("deltas: %+v", f.deltas)
	}
	if m.c[MetricApplied] != 1 {
		t.Fatal("applied metric")
	}
}

func TestDuplicateEventDeduped(t *testing.T) {
	f, m := &fakeStore{}, &fakeMetrics{}
	p := newM5(f, m)
	ev := consumer.RawEvent{Topic: dkd.TopicCustodyPassportCustodyInitializedV1,
		EventID: "dup", Value: []byte(`{"gpid":"GP-x-0198c0de-0000-7000-8000-000000000002"}`)}
	_ = p.Handle(context.Background(), ev)
	_ = p.Handle(context.Background(), ev)
	if f.deltas["GP-x-0198c0de-0000-7000-8000-000000000002"] != 1 {
		t.Fatal("dedup failed: delta applied twice")
	}
	if m.c[MetricDeduped] != 1 {
		t.Fatal("deduped metric")
	}
}

func TestOtherCustodyTopicsSkippedAsExtensionPoints(t *testing.T) {
	f, m := &fakeStore{}, &fakeMetrics{}
	ev := consumer.RawEvent{Topic: dkd.TopicCustodyPassportCustodyTransferredV1,
		EventID: "e2", Value: []byte(`{"gpid":"GP-x-y"}`)}
	if err := newM5(f, m).Handle(context.Background(), ev); err != nil {
		t.Fatal(err)
	}
	if len(f.deltas) != 0 {
		t.Fatal("transferred must not change counts (schema NEEDS-INFO)")
	}
	if m.c[MetricSkipped] != 1 {
		t.Fatal("skipped metric")
	}
}

func TestBadPayloadSkippedNotFailed(t *testing.T) {
	f, m := &fakeStore{}, &fakeMetrics{}
	ev := consumer.RawEvent{Topic: dkd.TopicCustodyPassportCustodyInitializedV1,
		EventID: "e3", Value: []byte(`not-json`)}
	if err := newM5(f, m).Handle(context.Background(), ev); err != nil {
		t.Fatal("unparsable payload must be skipped, not failed")
	}
	if m.c[MetricSkipped] != 1 {
		t.Fatal("skipped metric")
	}
}

func TestStoreErrorPropagates(t *testing.T) {
	f, m := &fakeStore{err: errors.New("db down")}, &fakeMetrics{}
	ev := consumer.RawEvent{Topic: dkd.TopicCustodyPassportCustodyInitializedV1, EventID: "e4",
		Value: []byte(`{"gpid":"GP-x-0198c0de-0000-7000-8000-000000000004"}`)}
	if err := newM5(f, m).Handle(context.Background(), ev); err == nil {
		t.Fatal("store error must propagate (consumer parks/replays)")
	}
}

func TestParkAcknowledges(t *testing.T) {
	f, m := &fakeStore{}, &fakeMetrics{}
	if ok := newM5(f, m).Park(consumer.RawEvent{EventID: "e5"}, errors.New("boom")); !ok {
		t.Fatal("park must acknowledge (projection is rebuildable)")
	}
	if m.c[MetricParked] != 1 {
		t.Fatal("parked metric")
	}
}
