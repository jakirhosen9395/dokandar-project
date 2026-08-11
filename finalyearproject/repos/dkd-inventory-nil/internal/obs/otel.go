// INV-04: real OpenTelemetry tracing — a TracerProvider with an OTLP/HTTP exporter (was a
// traceparent-string stub with no SDK/exporter). Spans are created per request and exported to the
// collector at DKD_OTLP_ENDPOINT; when unset the provider still records (SDK live) but does not export.
package obs

import (
	"context"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
	"go.opentelemetry.io/otel/trace"
)

// InitTracer builds a real OTel TracerProvider, installs it globally with W3C trace-context
// propagation, and returns the service tracer + a shutdown func. otlpEndpoint="" -> record-only
// (no exporter), so local/dev runs never block on a collector.
func InitTracer(ctx context.Context, serviceName, otlpEndpoint string) (trace.Tracer, func(context.Context) error) {
	opts := []sdktrace.TracerProviderOption{
		sdktrace.WithResource(resource.NewWithAttributes(semconv.SchemaURL, semconv.ServiceName(serviceName))),
	}
	if otlpEndpoint != "" {
		cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		exp, err := otlptracehttp.New(cctx, otlptracehttp.WithEndpoint(otlpEndpoint), otlptracehttp.WithInsecure())
		if err == nil {
			opts = append(opts, sdktrace.WithBatcher(exp))
		}
	}
	tp := sdktrace.NewTracerProvider(opts...)
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(propagation.TraceContext{}, propagation.Baggage{}))
	return tp.Tracer(serviceName), tp.Shutdown
}
