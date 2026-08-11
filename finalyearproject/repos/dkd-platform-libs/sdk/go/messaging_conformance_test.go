package dkdplatform

import (
	"context"
	"fmt"
	"strings"
	"testing"
)

// --- in-memory fake implementing the minimal DB interface -------------------
// It records every SQL + params issued and enforces the same uniqueness the
// canonical schema does (outbox.event_id UNIQUE, inbox composite PK, dlq
// aggregate_key existence), so the conformance test proves real semantics
// without a live database.

type sqlCall struct {
	sql  string
	args []any
}

type fakeDB struct {
	calls     []sqlCall
	outbox    map[string]bool // event_id -> present
	inbox     map[string]bool // consumer|event_id -> present
	dlqByKey  map[string]bool // aggregate_key -> parked
	published map[int64]bool
}

func newFakeDB() *fakeDB {
	return &fakeDB{
		outbox:    map[string]bool{},
		inbox:     map[string]bool{},
		dlqByKey:  map[string]bool{},
		published: map[int64]bool{},
	}
}

type fakeResult struct{ affected int64 }

func (r fakeResult) RowsAffected() (int64, error) { return r.affected, nil }

type fakeRows struct {
	data [][]any
	pos  int
}

func (r *fakeRows) Next() bool {
	if r.pos >= len(r.data) {
		return false
	}
	r.pos++
	return true
}
func (r *fakeRows) Scan(dest ...any) error {
	row := r.data[r.pos-1]
	if len(dest) != len(row) {
		return fmt.Errorf("scan: want %d dest, got %d", len(row), len(dest))
	}
	for i, d := range dest {
		switch p := d.(type) {
		case *int:
			p2, _ := row[i].(int)
			*p = p2
		case *int64:
			*p = row[i].(int64)
		case *string:
			*p = row[i].(string)
		case *[]byte:
			*p = row[i].([]byte)
		default:
			return fmt.Errorf("scan: unsupported dest type %T", d)
		}
	}
	return nil
}
func (r *fakeRows) Close() error { return nil }
func (r *fakeRows) Err() error   { return nil }

type fakeRow struct{ err error }

func (r fakeRow) Scan(dest ...any) error { return r.err }

func (f *fakeDB) ExecContext(_ context.Context, q string, args ...any) (Result, error) {
	f.calls = append(f.calls, sqlCall{sql: q, args: args})
	switch {
	case strings.Contains(q, "INSERT INTO outbox"):
		id := args[0].(string)
		if f.outbox[id] { // ON CONFLICT DO NOTHING
			return fakeResult{0}, nil
		}
		f.outbox[id] = true
		return fakeResult{1}, nil
	case strings.Contains(q, "INSERT INTO inbox"):
		k := args[0].(string) + "|" + args[1].(string)
		if f.inbox[k] {
			return fakeResult{0}, nil
		}
		f.inbox[k] = true
		return fakeResult{1}, nil
	case strings.Contains(q, "INSERT INTO dlq"):
		f.dlqByKey[args[5].(string)] = true // aggregate_key is the 6th column
		return fakeResult{1}, nil
	case strings.Contains(q, "UPDATE outbox SET published_at"):
		for _, a := range args {
			f.published[a.(int64)] = true
		}
		return fakeResult{int64(len(args))}, nil
	}
	return fakeResult{0}, nil
}

func (f *fakeDB) QueryContext(_ context.Context, q string, args ...any) (Rows, error) {
	f.calls = append(f.calls, sqlCall{sql: q, args: args})
	switch {
	case strings.Contains(q, "FROM inbox WHERE consumer"):
		if f.inbox[args[0].(string)+"|"+args[1].(string)] {
			return &fakeRows{data: [][]any{{1}}}, nil
		}
		return &fakeRows{}, nil
	case strings.Contains(q, "FROM dlq WHERE aggregate_key"):
		if f.dlqByKey[args[0].(string)] {
			return &fakeRows{data: [][]any{{1}}}, nil
		}
		return &fakeRows{}, nil
	case strings.Contains(q, "FROM outbox WHERE published_at IS NULL"):
		var data [][]any
		if !f.published[1] {
			data = append(data, []any{int64(1), "ev-fetch", "custody.passport.CustodyInitialized.v1",
				"PPID-1", []byte(`{"a":1}`), int64(42)})
		}
		return &fakeRows{data: data}, nil
	}
	return &fakeRows{}, nil
}

func (f *fakeDB) QueryRowContext(_ context.Context, q string, args ...any) Row {
	f.calls = append(f.calls, sqlCall{sql: q, args: args})
	return fakeRow{}
}

func (f *fakeDB) lastInsertInto(table string) (sqlCall, bool) {
	for i := len(f.calls) - 1; i >= 0; i-- {
		if strings.Contains(f.calls[i].sql, "INSERT INTO "+table) {
			return f.calls[i], true
		}
	}
	return sqlCall{}, false
}

// --- conformance ------------------------------------------------------------

func TestOutboxEnqueueInsertsOnceOnConflictDoNothing(t *testing.T) {
	// Arrange
	db := newFakeDB()
	rec := OutboxRecord{EventID: "ev-1", Topic: "custody.passport.CustodyTransferred.v1",
		Key: "PPID-9", Payload: []byte(`{"x":1}`), OccurredAtMs: 1700000000000}

	// Act
	if err := (Outbox{}).Enqueue(context.Background(), db, rec); err != nil {
		t.Fatalf("enqueue: %v", err)
	}

	// Assert: exactly one INSERT INTO outbox, ON CONFLICT DO NOTHING, right columns/params
	call, ok := db.lastInsertInto("outbox")
	if !ok {
		t.Fatal("no INSERT INTO outbox issued")
	}
	for _, want := range []string{"event_id", "topic", "key", "payload", "occurred_at_ms",
		"ON CONFLICT (event_id) DO NOTHING"} {
		if !strings.Contains(call.sql, want) {
			t.Fatalf("outbox insert missing %q in:\n%s", want, call.sql)
		}
	}
	if len(call.args) != 5 || call.args[0] != "ev-1" || call.args[4].(int64) != 1700000000000 {
		t.Fatalf("outbox insert params wrong: %#v", call.args)
	}
	inserts := 0
	for _, c := range db.calls {
		if strings.Contains(c.sql, "INSERT INTO outbox") {
			inserts++
		}
	}
	if inserts != 1 {
		t.Fatalf("want exactly 1 outbox insert, got %d", inserts)
	}
}

func TestOutboxEnqueueDuplicateEventIDIsNoOp(t *testing.T) {
	db := newFakeDB()
	rec := OutboxRecord{EventID: "dup-1", Topic: "t", Key: "k", Payload: []byte(`{}`), OccurredAtMs: 1}

	if err := (Outbox{}).Enqueue(context.Background(), db, rec); err != nil {
		t.Fatalf("first enqueue: %v", err)
	}
	if err := (Outbox{}).Enqueue(context.Background(), db, rec); err != nil {
		t.Fatalf("second enqueue must be a no-op, not an error: %v", err)
	}
	if len(db.outbox) != 1 {
		t.Fatalf("duplicate event_id must not create a second row, have %d", len(db.outbox))
	}
}

func TestOutboxRelayFetchMarkAndHeaders(t *testing.T) {
	db := newFakeDB()
	relay := OutboxRelay{ProducerContext: "custody"}

	rows, err := relay.FetchUnpublished(context.Background(), db, 10)
	if err != nil || len(rows) != 1 || rows[0].EventID != "ev-fetch" {
		t.Fatalf("fetch unpublished: %v rows=%#v", err, rows)
	}
	if err := relay.MarkPublished(context.Background(), db, []int64{rows[0].ID}); err != nil {
		t.Fatalf("mark published: %v", err)
	}
	if !db.published[1] {
		t.Fatal("row 1 should be marked published")
	}
	again, _ := relay.FetchUnpublished(context.Background(), db, 10)
	if len(again) != 0 {
		t.Fatalf("published row must not be re-fetched, got %d", len(again))
	}

	// Headers: traceparent passed through when present; event_id + producer_context always.
	hs := relay.Headers(rows[0], "00-trace-01")
	got := map[string]string{}
	for _, h := range hs {
		got[h.Key] = string(h.Value)
	}
	if got["traceparent"] != "00-trace-01" || got["event_id"] != "ev-fetch" || got["producer_context"] != "custody" {
		t.Fatalf("headers wrong: %#v", got)
	}
	// Stub-safe: no traceparent supplied -> header omitted, others still present.
	hs2 := relay.Headers(rows[0], "")
	for _, h := range hs2 {
		if h.Key == "traceparent" {
			t.Fatal("traceparent must be omitted when none supplied")
		}
	}
	if len(hs2) != 2 {
		t.Fatalf("want event_id + producer_context, got %d headers", len(hs2))
	}
}

func TestInboxMarkThenAlreadyProcessed(t *testing.T) {
	db := newFakeDB()
	ib := Inbox{}
	ctx := context.Background()

	pre, err := ib.AlreadyProcessed(ctx, db, "inventory", "ev-77")
	if err != nil || pre {
		t.Fatalf("expected not-yet-processed: %v processed=%v", err, pre)
	}
	if err := ib.MarkProcessed(ctx, db, "inventory", "ev-77"); err != nil {
		t.Fatalf("mark processed: %v", err)
	}
	post, err := ib.AlreadyProcessed(ctx, db, "inventory", "ev-77")
	if err != nil || !post {
		t.Fatalf("expected processed after mark: %v processed=%v", err, post)
	}
	// dedup is per-consumer: a different consumer has NOT processed it.
	other, _ := ib.AlreadyProcessed(ctx, db, "analytics", "ev-77")
	if other {
		t.Fatal("dedup must be scoped per consumer")
	}
}

func TestDlqParkFreezesOnlyThatAggregateKey(t *testing.T) {
	db := newFakeDB()
	dlq := Dlq{}
	ctx := context.Background()

	err := dlq.Park(ctx, db, DlqRecord{EventID: "poison-1", Topic: "finance.wallet.Debited.v1",
		Key: "WLT-5", Payload: []byte(`{}`), Error: "boom", AggregateKey: "WLT-5"})
	if err != nil {
		t.Fatalf("park: %v", err)
	}
	call, ok := db.lastInsertInto("dlq")
	if !ok || !strings.Contains(call.sql, "aggregate_key") {
		t.Fatalf("dlq insert must record aggregate_key: ok=%v sql=%s", ok, call.sql)
	}
	if call.args[5] != "WLT-5" {
		t.Fatalf("aggregate_key param wrong: %#v", call.args)
	}

	parked, err := dlq.IsKeyParked(ctx, db, "WLT-5")
	if err != nil || !parked {
		t.Fatalf("WLT-5 should be parked: %v parked=%v", err, parked)
	}
	other, err := dlq.IsKeyParked(ctx, db, "WLT-6")
	if err != nil || other {
		t.Fatalf("WLT-6 must NOT be parked (only the poison key freezes): %v parked=%v", err, other)
	}
}
