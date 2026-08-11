// EDGE-03: real OpenTelemetry tracing for the API gateway — a TracerProvider with an OTLP/HTTP
// exporter (DKD_OTLP_ENDPOINT) + W3C trace-context propagation, and a span-wrapping middleware so
// every proxied request carries an edge span that downstream services continue.
package main

import (
	"context"
	"net/http"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

func initTracer(ctx context.Context, serviceName, otlpEndpoint string) func(context.Context) error {
	opts := []sdktrace.TracerProviderOption{
		sdktrace.WithResource(resource.NewWithAttributes(semconv.SchemaURL, semconv.ServiceName(serviceName))),
	}
	if otlpEndpoint != "" {
		cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		if exp, err := otlptracehttp.New(cctx, otlptracehttp.WithEndpoint(otlpEndpoint), otlptracehttp.WithInsecure()); err == nil {
			opts = append(opts, sdktrace.WithBatcher(exp))
		}
	}
	tp := sdktrace.NewTracerProvider(opts...)
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(propagation.TraceContext{}, propagation.Baggage{}))
	return tp.Shutdown
}

// spanMiddleware starts an edge span per request and injects the propagated trace context so the
// downstream service's OTel span links to this one.
func spanMiddleware(next http.Handler) http.Handler {
	prop := otel.GetTextMapPropagator()
	tr := otel.Tracer("api-gateway-svc")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx := prop.Extract(r.Context(), propagation.HeaderCarrier(r.Header))
		ctx, span := tr.Start(ctx, r.Method+" "+r.URL.Path)
		defer span.End()
		prop.Inject(ctx, propagation.HeaderCarrier(r.Header)) // forward traceparent downstream
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}
