//go:build integration

// INV-01: real coverage of the inventory business core — the G2 CAS reserve (BR-022
// negative-stock-impossible), idempotent replay, and the strong-LOCAL available computation.
// Runs against an ephemeral Postgres via DKD_TEST_DB_DSN (the integration CI stage / a local infra).
package store

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync"
	"testing"
	"time"
)

func testStore(t *testing.T) (*Store, string, string) {
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
	if err := s.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	// unique (gpid,holder) per test so the shared DB never cross-contaminates.
	n := time.Now().UnixNano()
	return s, fmt.Sprintf("GP-test-%d", n), fmt.Sprintf("did:dokandar:test-%d", n)
}

func TestReserve_NegativeStockImpossible(t *testing.T) {
	s, gpid, holder := testStore(t)
	ctx := context.Background()
	now := time.Now().UnixMilli()

	// genesis 30 on-hand
	if _, err := s.InitLotOnce(ctx, "ev-init-"+gpid, Lot{PPID: "PP-" + gpid, GPID: gpid, Holder: holder, Quantity: 30, Unit: "kg"}, now); err != nil {
		t.Fatalf("init lot: %v", err)
	}

	// reserve 10 -> OK, available 20
	if _, err := s.Reserve(ctx, "idem-a-"+gpid, gpid, holder, 10, now); err != nil {
		t.Fatalf("reserve 10: %v", err)
	}
	ls, _ := s.Local(ctx, gpid, holder)
	if ls.OnHand != 30 || ls.Held != 10 || ls.Available != 20 {
		t.Fatalf("after reserve 10: %+v (want onHand30 held10 avail20)", ls)
	}

	// reserve 25 -> MUST fail (25 > 20 available): negative stock impossible (BR-022)
	if _, err := s.Reserve(ctx, "idem-b-"+gpid, gpid, holder, 25, now); !errors.Is(err, ErrInsufficientStock) {
		t.Fatalf("reserve 25 must be ErrInsufficientStock, got %v", err)
	}

	// idempotent replay of idem-a -> SAME reservation, held unchanged (still 10)
	r1, _ := s.Reserve(ctx, "idem-a-"+gpid, gpid, holder, 10, now)
	ls, _ = s.Local(ctx, gpid, holder)
	if ls.Held != 10 || r1.State != ResHeld {
		t.Fatalf("idempotent replay changed held: %+v", ls)
	}

	// reserve the remaining 20 -> OK, available 0
	if _, err := s.Reserve(ctx, "idem-c-"+gpid, gpid, holder, 20, now); err != nil {
		t.Fatalf("reserve 20: %v", err)
	}
	ls, _ = s.Local(ctx, gpid, holder)
	if ls.Available != 0 {
		t.Fatalf("available must be 0, got %d", ls.Available)
	}

	// reserve 1 more against 0 available -> fail
	if _, err := s.Reserve(ctx, "idem-d-"+gpid, gpid, holder, 1, now); !errors.Is(err, ErrInsufficientStock) {
		t.Fatalf("reserve 1 against empty must fail, got %v", err)
	}

	// non-positive quantity rejected
	if _, err := s.Reserve(ctx, "idem-z-"+gpid, gpid, holder, 0, now); err == nil {
		t.Fatal("zero quantity must be rejected")
	}
}

func TestReserve_ConcurrentNoOverAllocation(t *testing.T) {
	s, gpid, holder := testStore(t)
	ctx := context.Background()
	now := time.Now().UnixMilli()
	if _, err := s.InitLotOnce(ctx, "ev-init2-"+gpid, Lot{PPID: "PP2-" + gpid, GPID: gpid, Holder: holder, Quantity: 100, Unit: "kg"}, now); err != nil {
		t.Fatalf("init: %v", err)
	}
	// 30 concurrent reservers of 5 each want 150 total against 100 on-hand — the CAS lock must let
	// EXACTLY 20 succeed (100/5) and the rest fail; NEVER over-allocate below zero.
	var wg sync.WaitGroup
	var mu sync.Mutex
	ok := 0
	for i := 0; i < 30; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			if _, err := s.Reserve(ctx, fmt.Sprintf("idem-conc-%s-%d", gpid, i), gpid, holder, 5, now); err == nil {
				mu.Lock()
				ok++
				mu.Unlock()
			}
		}(i)
	}
	wg.Wait()
	if ok != 20 {
		t.Fatalf("expected exactly 20 successful reserves (100/5), got %d", ok)
	}
	ls, _ := s.Local(ctx, gpid, holder)
	if ls.Held != 100 || ls.Available != 0 {
		t.Fatalf("held must be exactly 100, available 0: %+v", ls)
	}
}

func TestReserve_ReleaseRestoresAvailability(t *testing.T) {
	s, gpid, holder := testStore(t)
	ctx := context.Background()
	now := time.Now().UnixMilli()
	_, _ = s.InitLotOnce(ctx, "ev-init3-"+gpid, Lot{PPID: "PP3-" + gpid, GPID: gpid, Holder: holder, Quantity: 10, Unit: "kg"}, now)
	r, err := s.Reserve(ctx, "idem-rel-"+gpid, gpid, holder, 10, now)
	if err != nil {
		t.Fatalf("reserve: %v", err)
	}
	if ls, _ := s.Local(ctx, gpid, holder); ls.Available != 0 {
		t.Fatalf("available should be 0, got %d", ls.Available)
	}
	if _, err := s.Transition(ctx, r.ResID, "RELEASED", now); err != nil {
		t.Fatalf("release: %v", err)
	}
	if ls, _ := s.Local(ctx, gpid, holder); ls.Available != 10 {
		t.Fatalf("release must restore availability to 10, got %d", ls.Available)
	}
}
