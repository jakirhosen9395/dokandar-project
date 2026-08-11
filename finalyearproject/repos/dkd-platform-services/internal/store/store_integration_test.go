//go:build integration

// PLAT-07: real coverage of the platform scheduler/notification store core — FireOnce idempotency
// (a timer must NEVER double-fire: a re-delivered tick writes no second outbox event) and InsertJob
// dedup on the idempotency key. Runs against an ephemeral Postgres via DKD_TEST_DB_DSN.
package store

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"
)

func testStore(t *testing.T) (*Store, string) {
	t.Helper()
	dsn := os.Getenv("DKD_TEST_DB_DSN")
	if dsn == "" {
		t.Skip("DKD_TEST_DB_DSN not set — integration DB required")
	}
	ctx := context.Background()
	s, err := Open(ctx, dsn)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(s.Close)
	if err := s.MigrateScheduler(ctx, time.Now().UnixMilli()); err != nil {
		t.Fatalf("migrate scheduler: %v", err)
	}
	if err := s.MigrateNotification(ctx, time.Now().UnixMilli()); err != nil {
		t.Fatalf("migrate notification: %v", err)
	}
	return s, fmt.Sprintf("test-%d", time.Now().UnixNano())
}

func TestFireOnce_NeverDoubleFires(t *testing.T) {
	s, key := testStore(t)
	ctx := context.Background()
	now := time.Now().UnixMilli()
	ev := OutboxRow{EventID: "ev-" + key, Topic: "platform.scheduler.EscrowCoolingOffElapsed.v1", Key: key, Payload: []byte(`{}`)}

	// first tick fires
	fired, err := s.FireOnce(ctx, key, ev, now)
	if err != nil || !fired {
		t.Fatalf("first FireOnce should fire: fired=%v err=%v", fired, err)
	}
	// a re-delivered / duplicate tick for the SAME key MUST NOT fire again (no second outbox event)
	fired2, err := s.FireOnce(ctx, key, OutboxRow{EventID: "ev2-" + key, Topic: ev.Topic, Key: key, Payload: []byte(`{}`)}, now+1)
	if err != nil {
		t.Fatalf("second FireOnce err: %v", err)
	}
	if fired2 {
		t.Fatal("duplicate tick double-fired the timer — idempotency broken")
	}
	// exactly one outbox row exists for this key
	var n int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM scheduler_outbox WHERE partition_key=$1`, key).Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 1 {
		t.Fatalf("expected exactly 1 outbox event, got %d", n)
	}
}

func TestInsertJob_DedupsOnIdempotencyKey(t *testing.T) {
	s, key := testStore(t)
	ctx := context.Background()
	job := Job{NtfID: "NTF-" + key, RecipientDid: "did:dokandar:" + key, Channel: "SMS",
		TemplateID: "ORDER_PLACED", Params: []byte(`{}`), Locale: "bn-BD", Body: "x", Status: "PENDING", CreatedAt: time.Now().UnixMilli()}

	ins, err := s.InsertJob(ctx, job, "idem-"+key)
	if err != nil || !ins {
		t.Fatalf("first InsertJob should insert: ins=%v err=%v", ins, err)
	}
	ins2, err := s.InsertJob(ctx, job, "idem-"+key)
	if err != nil {
		t.Fatalf("second InsertJob err: %v", err)
	}
	if ins2 {
		t.Fatal("duplicate idempotency key was inserted twice — dedup broken")
	}
}
