package obs

import (
	"context"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
)

func TestNewLogger(t *testing.T) {
	if NewLogger() == nil {
		t.Fatal("logger must not be nil")
	}
}

func TestMetricsIncAndHandler(t *testing.T) {
	m := NewMetrics()
	m.Inc("custody_commands_total")
	m.Inc("custody_commands_total")
	w := httptest.NewRecorder()
	m.Handler().ServeHTTP(w, httptest.NewRequest("GET", "/metrics", nil))
	if !strings.Contains(w.Body.String(), "custody_commands_total 2") {
		t.Fatalf("metrics body: %s", w.Body.String())
	}
	if ct := w.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/plain") {
		t.Fatalf("content-type: %s", ct)
	}
}

func TestNewTraceParentIsW3C(t *testing.T) {
	tp := NewTraceParent()
	if !regexp.MustCompile(`^00-[0-9a-f]{32}-[0-9a-f]{16}-01$`).MatchString(tp) {
		t.Fatalf("traceparent: %s", tp)
	}
	if tp == NewTraceParent() {
		t.Fatal("traceparents must be unique")
	}
}

func TestCorrelationIDRoundTrip(t *testing.T) {
	ctx := context.WithValue(context.Background(), CorrelationIDKey, "cid-1")
	if CorrelationID(ctx) != "cid-1" {
		t.Fatal("correlation id must round-trip")
	}
	if CorrelationID(context.Background()) != "" {
		t.Fatal("absent correlation id must be empty")
	}
}
