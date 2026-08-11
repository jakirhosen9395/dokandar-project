package logistics

import (
	"regexp"
	"testing"
)

func TestStateMachine(t *testing.T) {
	cases := []struct {
		from, to Status
		ok       bool
	}{
		{StatusPending, StatusRiderAssigned, true},
		{StatusPending, StatusCancelled, true},
		{StatusPending, StatusPickedUp, false},
		{StatusPending, StatusDelivered, false},
		{StatusRiderAssigned, StatusPickedUp, true},
		{StatusRiderAssigned, StatusCancelled, true},
		{StatusRiderAssigned, StatusDelivered, false},
		{StatusPickedUp, StatusDelivered, true},
		{StatusPickedUp, StatusFailed, true},
		{StatusPickedUp, StatusCancelled, true},
		{StatusDelivered, StatusCancelled, false},
		{StatusCancelled, StatusRiderAssigned, false},
		{StatusFailed, StatusDelivered, false},
	}
	for _, c := range cases {
		if got := CanTransition(c.from, c.to); got != c.ok {
			t.Errorf("%s -> %s: got %v want %v", c.from, c.to, got, c.ok)
		}
	}
}

func TestTerminals(t *testing.T) {
	for _, s := range []Status{StatusDelivered, StatusCancelled, StatusFailed} {
		if !IsTerminal(s) {
			t.Errorf("%s must be terminal", s)
		}
	}
	for _, s := range []Status{StatusPending, StatusRiderAssigned, StatusPickedUp} {
		if IsTerminal(s) {
			t.Errorf("%s must not be terminal", s)
		}
	}
}

func TestReferenceTypes(t *testing.T) {
	if !ValidReferenceType("ORDER") || !ValidReferenceType("TRADE") {
		t.Fatal("ORDER and TRADE are the canon reference types")
	}
	if ValidReferenceType("GIFT") || ValidReferenceType("") {
		t.Fatal("unknown reference types must be rejected")
	}
}

func TestSHPShape(t *testing.T) {
	re := regexp.MustCompile(`^SHP-[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	seen := map[string]bool{}
	for i := 0; i < 1000; i++ {
		id := NewSHP()
		if !re.MatchString(id) {
			t.Fatalf("bad SHP shape: %s", id)
		}
		if seen[id] {
			t.Fatalf("duplicate SHP: %s", id)
		}
		seen[id] = true
	}
}
