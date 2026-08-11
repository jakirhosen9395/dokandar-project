package obs

import (
	"context"
	"crypto/rand"
	"encoding/hex"
)

type ctxKey string

const (
	CorrelationIDKey ctxKey = "correlation_id"
	TraceParentKey   ctxKey = "traceparent"
)

// NewTraceParent generates a W3C traceparent. The OpenTelemetry SDK is the integration point for
// span export; propagation works without it.
func NewTraceParent() string {
	tid := make([]byte, 16)
	sid := make([]byte, 8)
	_, _ = rand.Read(tid)
	_, _ = rand.Read(sid)
	return "00-" + hex.EncodeToString(tid) + "-" + hex.EncodeToString(sid) + "-01"
}

func CorrelationID(ctx context.Context) string {
	if v, ok := ctx.Value(CorrelationIDKey).(string); ok {
		return v
	}
	return ""
}
