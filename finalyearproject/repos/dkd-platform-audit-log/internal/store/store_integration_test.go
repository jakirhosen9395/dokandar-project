//go:build integration

package store

import (
	"context"
	"os"
	"testing"
	"time"

	"gitlab.com/final-year-project3354127/audit-log-svc/internal/audit"
)

func testDSN(t *testing.T) string {
	d := os.Getenv("DKD_TEST_DB_DSN")
	if d == "" {
		d = os.Getenv("DKD_DB_DSN")
	}
	if d == "" {
		t.Skip("no DKD_TEST_DB_DSN/DKD_DB_DSN set; store integration test skipped")
	}
	return d
}

func openStore(t *testing.T) *Postgres {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	s, err := Open(ctx, testDSN(t))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if err := s.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	if err := s.Ping(ctx); err != nil {
		t.Fatalf("ping: %v", err)
	}
	return s
}

func uniqueID(prefix string) string {
	return prefix + "-" + time.Now().UTC().Format("150405.000000000")
}

func TestAppendDedupAndWORM(t *testing.T) {
	ctx := context.Background()
	s := openStore(t)
	defer s.Close()

	eid := uniqueID("it-append")
	rec := audit.Record{EventID: eid, Topic: "platform.test.T.v1", Key: "K", Payload: []byte(`{"did":"x"}`), IngestedAtMs: time.Now().UnixMilli()}

	ins, err := s.Append(ctx, rec)
	if err != nil || !ins {
		t.Fatalf("first append: ins=%v err=%v", ins, err)
	}
	ins2, err := s.Append(ctx, rec) // same event_id → inbox dedup
	if err != nil || ins2 {
		t.Fatalf("dedup: want ins=false err=nil, got ins=%v err=%v", ins2, err)
	}
	n, err := s.QueryRowInt(ctx, `SELECT count(*) FROM audit_log WHERE event_id=$1`, eid)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("want exactly 1 row after re-deliver, got %d", n)
	}

	// WORM: UPDATE and DELETE must both be rejected.
	if err := s.Exec(ctx, `UPDATE audit_log SET topic='mutated' WHERE event_id=$1`, eid); err == nil {
		t.Fatal("UPDATE on audit_log must be rejected (WORM)")
	}
	if err := s.Exec(ctx, `DELETE FROM audit_log WHERE event_id=$1`, eid); err == nil {
		t.Fatal("DELETE on audit_log must be rejected (WORM)")
	}
}

func TestQuarantineAndDLQ(t *testing.T) {
	ctx := context.Background()
	s := openStore(t)
	defer s.Close()

	eid := uniqueID("it-quar")
	rec := audit.Record{EventID: eid, Topic: "t", Payload: []byte(`{"email":"a@b.com"}`),
		PIIFlagged: true, PIIFields: []string{"value:contact(email)"}, IngestedAtMs: time.Now().UnixMilli()}
	if _, err := s.Append(ctx, rec); err != nil {
		t.Fatal(err)
	}
	if err := s.QuarantinePII(ctx, rec); err != nil {
		t.Fatal(err)
	}
	if n, _ := s.QueryRowInt(ctx, `SELECT count(*) FROM audit_pii_quarantine WHERE event_id=$1`, eid); n != 1 {
		t.Fatalf("quarantine rows=%d", n)
	}
	if err := s.ParkDLQ(ctx, audit.RawEvent{EventID: eid, Topic: "t", Value: []byte("poison")}, "unparseable", time.Now().UnixMilli()); err != nil {
		t.Fatal(err)
	}
	if n, _ := s.QueryRowInt(ctx, `SELECT count(*) FROM audit_dlq WHERE event_id=$1`, eid); n != 1 {
		t.Fatalf("dlq rows=%d", n)
	}
}
