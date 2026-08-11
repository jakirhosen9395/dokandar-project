// Hand-authored primitive (PL-05). NOT dkdgen output: a W3C Trace Context
// `traceparent` parse/format/inject/extract helper plus a new-span-id
// generator, replacing the bare header passthrough. Full OTel-SDK span
// creation stays a service-level concern; the SDK owns only correct wire
// encoding of the traceparent header on outgoing HTTP and on event records
// (wired into OutboxRelay.Headers) and its extraction on the inbox side.
// Spec: W3C Trace Context — version-traceid-spanid-flags, all lowercase hex.

package dkdplatform

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/http"
	"strings"
)

// TraceHeaderName is the canonical W3C header/record-key for trace propagation.
const TraceHeaderName = "traceparent"

// TraceContext is a parsed W3C `traceparent`: an 8-bit version (only 00 is
// defined), a 128-bit trace id (32 hex), a 64-bit parent span id (16 hex), and
// 8 trace-flags bits (bit 0 = sampled).
type TraceContext struct {
	Version  byte
	TraceID  string // 32 lowercase hex
	SpanID   string // 16 lowercase hex
	Sampled  bool
}

// ParseTraceparent parses a W3C traceparent. It rejects a wrong field count,
// wrong field widths, non-hex characters, an unsupported/forbidden version
// (ff), and the all-zero trace id or span id (invalid per spec).
func ParseTraceparent(s string) (TraceContext, error) {
	var tc TraceContext
	parts := strings.Split(s, "-")
	if len(parts) != 4 {
		return tc, fmt.Errorf("traceparent %q must have 4 hyphen-separated fields", s)
	}
	if len(parts[0]) != 2 || len(parts[1]) != 32 || len(parts[2]) != 16 || len(parts[3]) != 2 {
		return tc, fmt.Errorf("traceparent %q has malformed field widths", s)
	}
	ver, err := hex.DecodeString(parts[0])
	if err != nil {
		return tc, fmt.Errorf("traceparent version not hex: %w", err)
	}
	if ver[0] == 0xff {
		return tc, fmt.Errorf("traceparent version ff is forbidden")
	}
	flags, err := hex.DecodeString(parts[3])
	if err != nil {
		return tc, fmt.Errorf("traceparent flags not hex: %w", err)
	}
	if !isLowerHex(parts[1]) || !isLowerHex(parts[2]) {
		return tc, fmt.Errorf("traceparent %q trace/span id not lowercase hex", s)
	}
	if isAllZero(parts[1]) {
		return tc, fmt.Errorf("traceparent trace id is all zero (invalid)")
	}
	if isAllZero(parts[2]) {
		return tc, fmt.Errorf("traceparent span id is all zero (invalid)")
	}
	tc.Version = ver[0]
	tc.TraceID = parts[1]
	tc.SpanID = parts[2]
	tc.Sampled = flags[0]&0x01 == 0x01
	return tc, nil
}

// Format renders the TraceContext back to canonical traceparent wire form.
// Parse(Format(tc)) round-trips.
func (tc TraceContext) Format() string {
	flags := byte(0)
	if tc.Sampled {
		flags = 0x01
	}
	return fmt.Sprintf("%02x-%s-%s-%02x", tc.Version, tc.TraceID, tc.SpanID, flags)
}

// NewTraceContext starts a fresh sampled root trace (new random trace id + span
// id, version 00). Use WithChildSpan to descend while keeping the trace id.
func NewTraceContext() TraceContext {
	return TraceContext{Version: 0, TraceID: NewTraceID(), SpanID: NewSpanID(), Sampled: true}
}

// WithChildSpan returns a copy carrying the SAME trace id but a fresh span id —
// the caller-side stamp for an outgoing hop.
func (tc TraceContext) WithChildSpan() TraceContext {
	tc.SpanID = NewSpanID()
	return tc
}

// NewSpanID returns 8 random bytes as 16 lowercase-hex chars (a fresh span id).
func NewSpanID() string { return randHex(8) }

// NewTraceID returns 16 random bytes as 32 lowercase-hex chars (a fresh trace id).
func NewTraceID() string { return randHex(16) }

func randHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(fmt.Sprintf("dkdplatform: trace entropy: %v", err))
	}
	return hex.EncodeToString(b)
}

// InjectHTTP writes the traceparent onto an outgoing request's headers.
func (tc TraceContext) InjectHTTP(h http.Header) { h.Set(TraceHeaderName, tc.Format()) }

// ExtractHTTP parses the traceparent from inbound request headers. ok is false
// when the header is absent or malformed.
func ExtractHTTP(h http.Header) (TraceContext, bool) {
	raw := h.Get(TraceHeaderName)
	if raw == "" {
		return TraceContext{}, false
	}
	tc, err := ParseTraceparent(raw)
	if err != nil {
		return TraceContext{}, false
	}
	return tc, true
}

// EventHeader renders the traceparent as a single Kafka record Header, so a
// producer can stamp it onto an event (R6: header carries no PII).
func (tc TraceContext) EventHeader() Header {
	return Header{Key: TraceHeaderName, Value: []byte(tc.Format())}
}

// HeadersWithTrace wires trace propagation into the PL-02 relay: it formats the
// TraceContext to a valid W3C traceparent and appends the standard relay
// headers (event_id, producer_context). This replaces passing a bare,
// unvalidated header string to OutboxRelay.Headers.
func (r OutboxRelay) HeadersWithTrace(row OutboxRow, tc TraceContext) []Header {
	return r.Headers(row, tc.Format())
}

// TraceparentFromEventHeaders extracts and validates the traceparent from a
// consumed event's record headers (inbox side). ok is false when absent/invalid.
func TraceparentFromEventHeaders(hs []Header) (TraceContext, bool) {
	for _, h := range hs {
		if h.Key == TraceHeaderName {
			tc, err := ParseTraceparent(string(h.Value))
			if err != nil {
				return TraceContext{}, false
			}
			return tc, true
		}
	}
	return TraceContext{}, false
}

func isLowerHex(s string) bool {
	for _, c := range s {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

func isAllZero(s string) bool {
	for _, c := range s {
		if c != '0' {
			return false
		}
	}
	return true
}
