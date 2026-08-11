package obs

import (
	"context"
	"testing"

	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
)

// INV-04: proves REAL OTel is wired (a live SDK that records spans), not a traceparent-string stub.
func TestInitTracer_recordsRealSpans(t *testing.T) {
	// record-only (no OTLP endpoint) still installs a live SDK TracerProvider.
	tr, shutdown := InitTracer(context.Background(), "platform-services-test", "")
	defer func() { _ = shutdown(context.Background()) }()

	// swap in an in-memory recorder to assert spans are actually produced by the SDK.
	rec := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(rec))
	tr = tp.Tracer("platform-services-test")

	_, span := tr.Start(context.Background(), "Reserve")
	span.End()

	ended := rec.Ended()
	if len(ended) != 1 {
		t.Fatalf("expected exactly 1 recorded span, got %d", len(ended))
	}
	if ended[0].Name() != "Reserve" {
		t.Fatalf("span name = %q, want Reserve", ended[0].Name())
	}
	if !ended[0].SpanContext().IsValid() {
		t.Fatal("span must carry a valid (non-stub) span context")
	}
}
