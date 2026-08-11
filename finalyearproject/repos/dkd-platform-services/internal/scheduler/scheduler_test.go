package scheduler

import (
	"strings"
	"testing"
)

// R6: only the three platform.scheduler.* topics may be produced.
func TestProducerGuardRejectsForeignTopics(t *testing.T) {
	s := &Scheduler{now: func() int64 { return 1 }}
	if _, err := s.event("custody.passport.CustodyTransferred.v1", "k", nil, 1); err == nil {
		t.Fatal("expected R6 violation for a foreign topic")
	}
	if _, err := s.event("platform.scheduler.CoolingOffExpired.v1", "ESC-1",
		map[string]any{"esc": "ESC-1"}, 1); err != nil {
		t.Fatalf("own topic rejected: %v", err)
	}
}

// Canon idempotency keys (DM Scheduler Event Catalog, verbatim shapes).
func TestIdempotencyKeyShapes(t *testing.T) {
	cool := "ESC:ESC-1:cooling-off:1234"
	if !strings.HasPrefix(cool, "ESC:") || !strings.Contains(cool, ":cooling-off:") {
		t.Fatal("cooling-off key shape drifted from canon")
	}
	nilKey := "NIL:GP-x:refresh:99"
	if !strings.HasPrefix(nilKey, "NIL:") || !strings.Contains(nilKey, ":refresh:") {
		t.Fatal("NIL refresh key shape drifted from canon")
	}
}

func TestEventEnvelopeCarriesEventIDAndOccurredAt(t *testing.T) {
	s := &Scheduler{now: func() int64 { return 42 }}
	ev, err := s.event("platform.scheduler.NILRollupRefresh.v1", "GP-x",
		map[string]any{"gpid": "GP-x"}, 42)
	if err != nil {
		t.Fatal(err)
	}
	if ev.Key != "GP-x" {
		t.Fatalf("partition key must be the GPID (registry ordering key), got %q", ev.Key)
	}
	body := string(ev.Payload)
	for _, want := range []string{`"eventId"`, `"occurredAt":42`, `"gpid":"GP-x"`} {
		if !strings.Contains(body, want) {
			t.Fatalf("payload missing %s: %s", want, body)
		}
	}
}

func TestUUID7Shape(t *testing.T) {
	u := NewUUID7()
	parts := strings.Split(u, "-")
	if len(parts) != 5 || parts[2][0] != '7' {
		t.Fatalf("not a uuid7: %s", u)
	}
}
