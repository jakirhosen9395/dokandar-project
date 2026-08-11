package ingest

import (
	"context"
	"errors"
	"io"
	"testing"

	"log/slog"

	"gitlab.com/final-year-project3354127/audit-log-svc/internal/audit"
)

type fakeStore struct {
	appended    []audit.Record
	quarantined []audit.Record
	parked      []audit.RawEvent
	dup         bool
	appendErr   error
	quarErr     error
	parkErr     error
}

func (f *fakeStore) Append(_ context.Context, rec audit.Record) (bool, error) {
	if f.appendErr != nil {
		return false, f.appendErr
	}
	if f.dup {
		return false, nil
	}
	f.appended = append(f.appended, rec)
	return true, nil
}
func (f *fakeStore) QuarantinePII(_ context.Context, rec audit.Record) error {
	f.quarantined = append(f.quarantined, rec)
	return f.quarErr
}
func (f *fakeStore) ParkDLQ(_ context.Context, e audit.RawEvent, _ string, _ int64) error {
	if f.parkErr != nil {
		return f.parkErr
	}
	f.parked = append(f.parked, e)
	return nil
}

type fakeMetrics struct{ c map[string]int }

func (m *fakeMetrics) Inc(name string) {
	if m.c == nil {
		m.c = map[string]int{}
	}
	m.c[name]++
}

func newIngestor(s Store, m Metrics) *Ingestor {
	return New(s, m, slog.New(slog.NewTextHandler(io.Discard, nil)), func() int64 { return 1719800000000 })
}

func TestHandleAppendsCleanRecord(t *testing.T) {
	s, m := &fakeStore{}, &fakeMetrics{}
	if err := newIngestor(s, m).Handle(context.Background(), audit.RawEvent{EventID: "e1", Value: []byte(`{"did":"x"}`)}); err != nil {
		t.Fatal(err)
	}
	if len(s.appended) != 1 {
		t.Fatalf("want 1 append got %d", len(s.appended))
	}
	if len(s.quarantined) != 0 {
		t.Fatal("clean record must not be quarantined")
	}
	if m.c[MetricIngested] != 1 {
		t.Fatal("ingested metric not incremented")
	}
}

// CORRECTION 1: a PII-shaped record is ALWAYS appended (append-all/WORM) AND quarantine-copied +
// metered. It is never dropped or rejected.
func TestHandleAlwaysAppendsPIIAndQuarantines(t *testing.T) {
	s, m := &fakeStore{}, &fakeMetrics{}
	if err := newIngestor(s, m).Handle(context.Background(), audit.RawEvent{EventID: "e2", Value: []byte(`{"rawNid":"1990123456789"}`)}); err != nil {
		t.Fatal(err)
	}
	if len(s.appended) != 1 {
		t.Fatal("PII record MUST still be appended (append-all/WORM)")
	}
	if len(s.quarantined) != 1 {
		t.Fatal("PII record must be quarantine-copied")
	}
	if m.c[MetricPIIFlagged] != 1 {
		t.Fatal("pii metric must increment")
	}
	if m.c[MetricIngested] != 1 {
		t.Fatal("ingested metric must increment (record still lands)")
	}
}

func TestHandleDedup(t *testing.T) {
	s, m := &fakeStore{dup: true}, &fakeMetrics{}
	if err := newIngestor(s, m).Handle(context.Background(), audit.RawEvent{EventID: "e3", Value: []byte(`{}`)}); err != nil {
		t.Fatal(err)
	}
	if m.c[MetricDeduped] != 1 {
		t.Fatal("deduped metric must increment")
	}
	if m.c[MetricIngested] != 0 {
		t.Fatal("duplicate must not count as ingested")
	}
}

func TestHandleAppendErrorReturnsForParking(t *testing.T) {
	s, m := &fakeStore{appendErr: errors.New("db down")}, &fakeMetrics{}
	if err := newIngestor(s, m).Handle(context.Background(), audit.RawEvent{EventID: "e4"}); err == nil {
		t.Fatal("append error must propagate so the consumer parks the record")
	}
}

func TestHandlePIIQuarantineErrorStillSucceeds(t *testing.T) {
	s, m := &fakeStore{quarErr: errors.New("quar fail")}, &fakeMetrics{}
	if err := newIngestor(s, m).Handle(context.Background(), audit.RawEvent{EventID: "e6", Value: []byte(`{"email":"a@b.com"}`)}); err != nil {
		t.Fatalf("quarantine-copy failure must not fail the pipeline: %v", err)
	}
	if len(s.appended) != 1 {
		t.Fatal("record still appended despite quarantine error")
	}
}

func TestParkSuccessReturnsTrue(t *testing.T) {
	s, m := &fakeStore{}, &fakeMetrics{}
	if ok := newIngestor(s, m).Park(audit.RawEvent{EventID: "e5"}, errors.New("boom")); !ok {
		t.Fatal("park must report success")
	}
	if len(s.parked) != 1 {
		t.Fatal("park must write to DLQ")
	}
	if m.c[MetricParked] != 1 {
		t.Fatal("parked metric must increment")
	}
}

// M1: when the DLQ write fails, Park returns false so the consumer does NOT commit the offset and
// the record replays (never silently dropped).
func TestParkFailureReturnsFalse(t *testing.T) {
	s, m := &fakeStore{parkErr: errors.New("dlq down")}, &fakeMetrics{}
	if ok := newIngestor(s, m).Park(audit.RawEvent{EventID: "e7"}, errors.New("boom")); ok {
		t.Fatal("park must report failure when the DLQ write fails")
	}
	if m.c[MetricParked] != 0 {
		t.Fatal("parked metric must NOT increment on failure")
	}
}
