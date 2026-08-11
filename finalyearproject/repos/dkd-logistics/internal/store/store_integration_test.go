//go:build integration

// LOG-05: real coverage of the logistics store business core — shipment creation idempotency, the
// DB-level state-machine transitions, LOG-02 idempotent same-state replay, and illegal-transition
// rejection. Runs against an ephemeral Postgres via DKD_TEST_DB_DSN.
package store

import (
	"context"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	"gitlab.com/final-year-project3354127/logistics-svc/internal/logistics"
)

func testStore(t *testing.T) (*Store, string) {
	t.Helper()
	dsn := os.Getenv("DKD_TEST_DB_DSN")
	if dsn == "" {
		t.Skip("DKD_TEST_DB_DSN not set — integration DB required")
	}
	s, err := Open(context.Background(), dsn)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(s.Close)
	if err := s.Migrate(context.Background()); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return s, fmt.Sprintf("ORD-test-%d", time.Now().UnixNano())
}

func ev(shp string) OutboxRow {
	return OutboxRow{EventID: "ev-" + shp + "-" + fmt.Sprint(time.Now().UnixNano()), Topic: "logistics.shipment.Test.v1", Key: shp, Payload: []byte(`{}`)}
}

func TestCreateShipment_Idempotent(t *testing.T) {
	s, ord := testStore(t)
	ctx := context.Background()
	now := time.Now().UnixMilli()
	sh1, created1, err := s.CreateShipment(ctx, "idem-"+ord, ord, "ORDER", nil, nil, ev, now)
	if err != nil || !created1 {
		t.Fatalf("first create: %v created=%v", err, created1)
	}
	if sh1.Status != logistics.StatusPending {
		t.Fatalf("new shipment must be PENDING, got %s", sh1.Status)
	}
	// re-create with the same idem key (or same reference) -> the existing shipment, created=false
	sh2, created2, err := s.CreateShipment(ctx, "idem-"+ord, ord, "ORDER", nil, nil, ev, now)
	if err != nil || created2 {
		t.Fatalf("replay create: %v created=%v (want created=false)", err, created2)
	}
	if sh2.SHP != sh1.SHP {
		t.Fatalf("idempotent create must return the SAME shipment: %s vs %s", sh1.SHP, sh2.SHP)
	}
}

func TestTransition_StateMachine_and_IdempotentReplay(t *testing.T) {
	s, ord := testStore(t)
	ctx := context.Background()
	now := time.Now().UnixMilli()
	sh, _, err := s.CreateShipment(ctx, "idem-"+ord, ord, "ORDER", nil, nil, ev, now)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	shp := sh.SHP

	// PENDING -> RIDER_ASSIGNED (legal)
	if _, err := s.Transition(ctx, shp, []logistics.Status{logistics.StatusPending}, logistics.StatusRiderAssigned,
		map[string]any{"assigned_rider_did": "did:dokandar:rider-1"}, ev(shp), now); err != nil {
		t.Fatalf("assign: %v", err)
	}

	// LOG-02: RIDER_ASSIGNED -> RIDER_ASSIGNED (already in target) is an idempotent 2xx replay, not 409
	if r, err := s.Transition(ctx, shp, []logistics.Status{logistics.StatusPending}, logistics.StatusRiderAssigned,
		map[string]any{}, ev(shp), now); err != nil || r.Status != logistics.StatusRiderAssigned {
		t.Fatalf("idempotent same-state replay must succeed: %v status=%s", err, r.Status)
	}

	// RIDER_ASSIGNED -> DELIVERED is ILLEGAL (must pass through PICKED_UP) -> ErrConflict
	if _, err := s.Transition(ctx, shp, []logistics.Status{logistics.StatusRiderAssigned}, logistics.StatusDelivered,
		map[string]any{}, ev(shp), now); !errors.Is(err, ErrConflict) {
		t.Fatalf("illegal skip-transition must be ErrConflict, got %v", err)
	}

	// legal path continues: -> PICKED_UP -> DELIVERED
	if _, err := s.Transition(ctx, shp, []logistics.Status{logistics.StatusRiderAssigned}, logistics.StatusPickedUp,
		map[string]any{}, ev(shp), now); err != nil {
		t.Fatalf("pickup: %v", err)
	}
	final, err := s.Transition(ctx, shp, []logistics.Status{logistics.StatusPickedUp}, logistics.StatusDelivered,
		map[string]any{"pod_photo_url": "https://x/pod.jpg"}, ev(shp), now)
	if err != nil || final.Status != logistics.StatusDelivered {
		t.Fatalf("deliver: %v status=%s", err, final.Status)
	}
}
