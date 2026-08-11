//go:build integration

package store

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/custody"
)

const (
	tHolder = "did:dokandar:0198c0de-0000-7000-8000-000000000001"
	tOther  = "did:dokandar:0198c0de-0000-7000-8000-000000000002"
)

func testStore(t *testing.T) *Store {
	t.Helper()
	dsn := os.Getenv("DKD_TEST_DB_DSN")
	if dsn == "" {
		t.Skip("DKD_TEST_DB_DSN not set; custody store integration test skipped")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	s, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	if err := s.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return s
}

func nowMs() int64 { return time.Now().UnixMilli() }

func initOnStore(t *testing.T, s *Store) (*custody.Passport, custody.Event) {
	t.Helper()
	p, ev, err := custody.InitializeCustody(custody.InitInput{
		GPID: "GP-rice-0198c0de-0000-7000-8000-000000000001", Holder: tHolder,
		HolderRole: custody.RoleProducer, Quantity: 5000, Unit: "kg", ProducedAt: nowMs(),
	}, nowMs())
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Append(context.Background(), ev, nowMs(),
		[]Affected{{Head: p, IsNew: true, RowPrevHash: ""}}); err != nil {
		t.Fatal(err)
	}
	return p, ev
}

// The full ledger lifecycle: genesis -> transfer -> verified chain.
func TestAppendTransferVerifyChain(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	p, _ := initOnStore(t, s)

	prevHead := p.HeadHash
	tev, err := p.Transfer(tHolder, tOther, custody.RoleTrader, "ORD-x", nowMs(), custody.TransferSig{FromKeyID: "kf", FromSignature: "c2ln", ToKeyID: "kt", ToSignature: "Y29zaWc="})
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Append(ctx, tev, nowMs(),
		[]Affected{{Head: p, IsNew: false, RowPrevHash: prevHead}}); err != nil {
		t.Fatal(err)
	}

	head, err := s.GetHead(ctx, p.PPID)
	if err != nil || head.CurrentHolder != tOther || head.Sequence != 2 {
		t.Fatalf("head: %+v err=%v", head, err)
	}
	ok, detail, err := s.VerifyChain(ctx, p.PPID)
	if err != nil || !ok {
		t.Fatalf("chain must verify: %s (%v)", detail, err)
	}
	rows, _ := s.ListEvents(ctx, p.PPID)
	if len(rows) != 2 || rows[1].PrevHash != rows[0].EventHash {
		t.Fatalf("linkage rows: %+v", rows)
	}
	// outbox got both events
	ob, _ := s.FetchUnpublished(ctx, 1000)
	found := 0
	for _, r := range ob {
		if r.Key == p.PPID {
			found++
		}
	}
	if found < 2 {
		t.Fatalf("outbox rows for ppid: %d", found)
	}
}

func TestSplitPersistsChildAnchors(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	p, _ := initOnStore(t, s)
	prevHead := p.HeadHash
	ev, children, err := p.Split([]custody.Alloc{
		{Holder: tHolder, HolderRole: custody.RoleTrader, Quantity: 4000},
		{Holder: tOther, HolderRole: custody.RoleTrader, Quantity: 1000},
	}, nowMs())
	if err != nil {
		t.Fatal(err)
	}
	affected := []Affected{{Head: p, IsNew: false, RowPrevHash: prevHead}}
	for _, c := range children {
		affected = append(affected, Affected{Head: c, IsNew: true, RowPrevHash: ""})
	}
	if err := s.Append(ctx, ev, nowMs(), affected); err != nil {
		t.Fatal(err)
	}
	for _, c := range children {
		ok, detail, err := s.VerifyChain(ctx, c.PPID)
		if err != nil || !ok {
			t.Fatalf("child chain must verify: %s (%v)", detail, err)
		}
	}
	ok, detail, _ := s.VerifyChain(ctx, p.PPID)
	if !ok {
		t.Fatalf("parent chain must verify after split: %s", detail)
	}
}

// WORM: UPDATE/DELETE on the ledger are rejected at the database layer.
func TestWORMRejectsMutation(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	p, _ := initOnStore(t, s)
	_, err := s.pool.Exec(ctx, "UPDATE passport_event SET event_hash='x' WHERE ppid=$1", p.PPID)
	if err == nil || !strings.Contains(err.Error(), "append-only") {
		t.Fatalf("UPDATE must be rejected by WORM trigger: %v", err)
	}
	_, err = s.pool.Exec(ctx, "DELETE FROM passport_event WHERE ppid=$1", p.PPID)
	if err == nil || !strings.Contains(err.Error(), "append-only") {
		t.Fatalf("DELETE must be rejected by WORM trigger: %v", err)
	}
}

// Optimistic concurrency: a stale head CAS loses with ErrSequenceConflict.
func TestSequenceConflict(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	p, _ := initOnStore(t, s)
	stale := *p // copy at seq 1
	prevHead := p.HeadHash
	ev1, err := p.Transfer(tHolder, tOther, custody.RoleTrader, "", nowMs(), custody.TransferSig{FromKeyID: "kf", FromSignature: "c2ln", ToKeyID: "kt", ToSignature: "Y29zaWc="})
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Append(ctx, ev1, nowMs(), []Affected{{Head: p, IsNew: false, RowPrevHash: prevHead}}); err != nil {
		t.Fatal(err)
	}
	ev2, err := stale.Transfer(tHolder, tOther, custody.RoleTrader, "", nowMs(), custody.TransferSig{FromKeyID: "kf", FromSignature: "c2ln", ToKeyID: "kt", ToSignature: "Y29zaWc="})
	if err != nil {
		t.Fatal(err)
	}
	err = s.Append(ctx, ev2, nowMs(), []Affected{{Head: &stale, IsNew: false, RowPrevHash: prevHead}})
	if !errors.Is(err, ErrSequenceConflict) {
		t.Fatalf("stale append must conflict, got %v", err)
	}
}

func TestRecallAndActiveByGPID(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	// unique gpid per run so ActiveByGPID counts are deterministic
	gpid := "GP-fish-0198c0de-0000-7000-8000-" + time.Now().UTC().Format("150405") + "000000"[:6]
	mk := func() (*custody.Passport, custody.Event) {
		p, ev, err := custody.InitializeCustody(custody.InitInput{
			GPID: gpid, Holder: tHolder, HolderRole: custody.RoleProducer,
			Quantity: 100, Unit: "kg", ProducedAt: nowMs(),
		}, nowMs())
		if err != nil {
			t.Fatal(err)
		}
		if err := s.Append(ctx, ev, nowMs(), []Affected{{Head: p, IsNew: true, RowPrevHash: ""}}); err != nil {
			t.Fatal(err)
		}
		return p, ev
	}
	a, _ := mk()
	b, _ := mk()
	active, err := s.ActiveByGPID(ctx, gpid, 0)
	if err != nil || len(active) != 2 {
		t.Fatalf("active: %d err=%v", len(active), err)
	}
	prevA, prevB := a.HeadHash, b.HeadHash
	rev, err := custody.RecallProducts([]*custody.Passport{a, b}, "rcl-it-1", "contamination", tHolder, nowMs())
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Append(ctx, rev, nowMs(), []Affected{
		{Head: a, IsNew: false, RowPrevHash: prevA},
		{Head: b, IsNew: false, RowPrevHash: prevB},
	}); err != nil {
		t.Fatal(err)
	}
	active, _ = s.ActiveByGPID(ctx, gpid, 0)
	if len(active) != 0 {
		t.Fatalf("recalled passports must leave ACTIVE set: %d", len(active))
	}
	for _, ppid := range []string{a.PPID, b.PPID} {
		ok, detail, err := s.VerifyChain(ctx, ppid)
		if err != nil || !ok {
			t.Fatalf("recalled chain must verify: %s (%v)", detail, err)
		}
	}
}

func TestInboxAndIdempotency(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	id := "cust-it-" + time.Now().UTC().Format("150405.000000000")
	dup, err := s.InboxSeen(ctx, id)
	if err != nil || dup {
		t.Fatalf("first: %v %v", dup, err)
	}
	dup, _ = s.InboxSeen(ctx, id)
	if !dup {
		t.Fatal("second sighting must dedup")
	}
	if err := s.PutIdem(ctx, id, "h", 201, []byte(`{"ok":true}`)); err != nil {
		t.Fatal(err)
	}
	status, hash, _, found, err := s.GetIdem(ctx, id)
	if err != nil || !found || status != 201 || hash != "h" {
		t.Fatalf("idem: %d %s %v %v", status, hash, found, err)
	}
}
