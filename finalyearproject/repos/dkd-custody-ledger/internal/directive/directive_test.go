package directive

import (
	"context"
	"errors"
	"io"
	"testing"

	"log/slog"

	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/consumer"
	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/custody"
	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/store"
)

const (
	dDID = "did:dokandar:0198c0de-0000-7000-8000-000000000001"
)

// fakeStore mimics the REAL store's replay semantics: ActiveByGPID re-reads FRESH heads
// (value copies), so a failed append leaves the gpid recallable on the next delivery.
type fakeStore struct {
	inbox     map[string]bool
	templates map[string]custody.Passport // gpid -> pristine ACTIVE head
	recalled  map[string]bool
	appends   int
	failGPID  string // Append fails while this gpid is still pending
	appendErr error
}

func (f *fakeStore) InboxSeen(_ context.Context, id string) (bool, error) {
	if f.inbox == nil {
		f.inbox = map[string]bool{}
	}
	dup := f.inbox[id]
	f.inbox[id] = true
	return dup, nil
}
func (f *fakeStore) ActiveByGPID(_ context.Context, gpid string, _ int) ([]*custody.Passport, error) {
	if f.recalled[gpid] {
		return nil, nil
	}
	t, ok := f.templates[gpid]
	if !ok {
		return nil, nil
	}
	cp := t
	return []*custody.Passport{&cp}, nil
}
func (f *fakeStore) Append(_ context.Context, ev custody.Event, _ int64, affected []store.Affected) error {
	if f.appendErr != nil && ev.Fields["gpid"] == f.failGPID {
		return f.appendErr
	}
	f.appends++
	if f.recalled == nil {
		f.recalled = map[string]bool{}
	}
	gpid, _ := ev.Fields["gpid"].(string)
	f.recalled[gpid] = true
	return nil
}

type fakeMetrics struct{ c map[string]int }

func (m *fakeMetrics) Inc(name string) {
	if m.c == nil {
		m.c = map[string]int{}
	}
	m.c[name]++
}

func mkActive(t *testing.T, gpid string) *custody.Passport {
	t.Helper()
	p, _, err := custody.InitializeCustody(custody.InitInput{
		GPID: gpid, Holder: dDID, HolderRole: custody.RoleProducer,
		Quantity: 10, Unit: "kg", ProducedAt: 1,
	}, 1)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func directiveEvent(id string) consumer.RawEvent {
	return consumer.RawEvent{EventID: id, Value: []byte(
		`{"recallId":"rcl-d1","gpids":["GP-a-0198c0de-0000-7000-8000-000000000001","GP-b-0198c0de-0000-7000-8000-000000000002"],"reason":"contamination","issuedBy":"` + dDID + `"}`)}
}

// C1 review fix: a partial multi-GPID failure replays and COMPLETES the remainder —
// the inbox must not short-circuit an incomplete directive.
func TestPartialFailureReplayCompletes(t *testing.T) {
	gA := "GP-a-0198c0de-0000-7000-8000-000000000001"
	gB := "GP-b-0198c0de-0000-7000-8000-000000000002"
	f := &fakeStore{templates: map[string]custody.Passport{
		gA: *mkActive(t, gA), gB: *mkActive(t, gB),
	}, failGPID: gB, appendErr: errors.New("db blip")}
	m := &fakeMetrics{}
	h := New(f, m, slog.New(slog.NewTextHandler(io.Discard, nil)), func() int64 { return 1 })

	if err := h.Handle(context.Background(), directiveEvent("dir-1")); err == nil {
		t.Fatal("partial failure must surface an error (partition replays)")
	}
	if f.appends != 1 || !f.recalled[gA] {
		t.Fatalf("first gpid must be recalled before the failure: appends=%d", f.appends)
	}
	if f.inbox["dir-1"] {
		t.Fatal("inbox must NOT be marked on partial failure")
	}
	// replay after the fault clears
	f.appendErr = nil
	if err := h.Handle(context.Background(), directiveEvent("dir-1")); err != nil {
		t.Fatal(err)
	}
	if f.appends != 2 || !f.recalled[gB] {
		t.Fatal("replay must complete the remaining gpid")
	}
	if !f.inbox["dir-1"] {
		t.Fatal("inbox marked only after full completion")
	}
	// clean redelivery: everything no-ops, dedup metric ticks
	if err := h.Handle(context.Background(), directiveEvent("dir-1")); err != nil {
		t.Fatal(err)
	}
	if f.appends != 2 {
		t.Fatal("redelivery must not re-append")
	}
	if m.c[MetricDeduped] != 1 {
		t.Fatal("dedup metric on clean redelivery")
	}
}

func TestUnparsableDirectiveSkipped(t *testing.T) {
	f := &fakeStore{}
	m := &fakeMetrics{}
	h := New(f, m, slog.New(slog.NewTextHandler(io.Discard, nil)), func() int64 { return 1 })
	if err := h.Handle(context.Background(), consumer.RawEvent{EventID: "junk-1", Value: []byte("junk")}); err != nil {
		t.Fatal("junk must be skipped, not failed")
	}
	if m.c[MetricSkipped] != 1 {
		t.Fatal("skipped metric")
	}
}

// Custody-critical: park must REFUSE to acknowledge (replay, never drop).
func TestParkRefuses(t *testing.T) {
	h := New(&fakeStore{}, &fakeMetrics{}, slog.New(slog.NewTextHandler(io.Discard, nil)), func() int64 { return 1 })
	if h.Park(consumer.RawEvent{EventID: "x"}, errors.New("boom")) {
		t.Fatal("park must return false for custody-critical directives")
	}
}
