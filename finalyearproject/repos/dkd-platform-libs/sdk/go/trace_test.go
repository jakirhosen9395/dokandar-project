package dkdplatform

import (
	"net/http"
	"testing"
)

func TestTraceparentRoundTrip(t *testing.T) {
	tc := NewTraceContext()
	if len(tc.TraceID) != 32 || len(tc.SpanID) != 16 {
		t.Fatalf("bad id widths: trace=%d span=%d", len(tc.TraceID), len(tc.SpanID))
	}
	wire := tc.Format()
	got, err := ParseTraceparent(wire)
	if err != nil {
		t.Fatalf("parse of own format failed: %v", err)
	}
	if got.Format() != wire {
		t.Fatalf("round-trip mismatch: %q != %q", got.Format(), wire)
	}
	if !got.Sampled {
		t.Fatal("sampled flag lost in round-trip")
	}
}

func TestParseTraceparentRejectsMalformed(t *testing.T) {
	bad := []string{
		"",
		"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331", // 3 fields
		"00-tooShortTrace-b7ad6b7169203331-01",
		"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-0", // 1-char flags
		"ff-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01", // forbidden version
		"00-00000000000000000000000000000000-b7ad6b7169203331-01", // zero trace id
		"00-0af7651916cd43dd8448eb211c80319c-0000000000000000-01", // zero span id
		"00-0AF7651916CD43DD8448EB211C80319C-b7ad6b7169203331-01", // uppercase
	}
	for _, s := range bad {
		if _, err := ParseTraceparent(s); err == nil {
			t.Errorf("expected rejection of %q", s)
		}
	}
}

func TestParseTraceparentKnownGood(t *testing.T) {
	// W3C spec example.
	tc, err := ParseTraceparent("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")
	if err != nil {
		t.Fatalf("spec example rejected: %v", err)
	}
	if tc.TraceID != "0af7651916cd43dd8448eb211c80319c" || tc.SpanID != "b7ad6b7169203331" || !tc.Sampled {
		t.Fatalf("parsed fields wrong: %+v", tc)
	}
}

func TestTraceInjectExtractHTTP(t *testing.T) {
	tc := NewTraceContext()
	h := http.Header{}
	tc.InjectHTTP(h)
	got, ok := ExtractHTTP(h)
	if !ok || got.Format() != tc.Format() {
		t.Fatalf("http inject/extract failed: ok=%v got=%q want=%q", ok, got.Format(), tc.Format())
	}
	if _, ok := ExtractHTTP(http.Header{}); ok {
		t.Fatal("empty header should extract nothing")
	}
}

func TestTraceWiresIntoOutboxRelay(t *testing.T) {
	tc := NewTraceContext().WithChildSpan()
	relay := OutboxRelay{ProducerContext: "custody"}
	hs := relay.HeadersWithTrace(OutboxRow{EventID: "evt-1"}, tc)
	got, ok := TraceparentFromEventHeaders(hs)
	if !ok {
		t.Fatal("traceparent header missing from relay output")
	}
	if got.TraceID != tc.TraceID {
		t.Fatalf("trace id not propagated: %q != %q", got.TraceID, tc.TraceID)
	}
}

func TestNewSpanIDDistinct(t *testing.T) {
	if NewSpanID() == NewSpanID() {
		t.Fatal("span ids should be unique")
	}
	if len(NewSpanID()) != 16 {
		t.Fatal("span id must be 16 hex chars")
	}
}
