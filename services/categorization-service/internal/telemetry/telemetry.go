// Package telemetry liga o OpenTelemetry (traces, métricas e logs via OTLP) e o log JSON no stdout.
// Tudo configurado pelas variáveis OTEL_* padrão; sem collector no ar o serviço segue normal.
package telemetry

import (
	"context"
	"errors"
	"log/slog"
	"os"

	"go.opentelemetry.io/contrib/bridges/otelslog"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/log/global"
	"go.opentelemetry.io/otel/propagation"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
	"go.opentelemetry.io/otel/trace"
)

// Setup devolve o logger e a função de desligamento (flush dos exporters).
func Setup(ctx context.Context, serviceName string) (*slog.Logger, func(context.Context) error) {
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(propagation.TraceContext{}, propagation.Baggage{}))
	stdout := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})

	if os.Getenv("OTEL_SDK_DISABLED") == "true" {
		return slog.New(withTraceIDs{stdout}).With("service", serviceName), func(context.Context) error { return nil }
	}

	// service.instance.id = hostname do container: com mais de uma réplica, sem ele as métricas de todas viram
	// uma série só no Prometheus e o contador "volta" a cada envio (increase() conta como reset)
	instance, _ := os.Hostname()
	res, _ := resource.New(ctx,
		resource.WithFromEnv(), // OTEL_SERVICE_NAME, OTEL_RESOURCE_ATTRIBUTES
		resource.WithHost(),
		resource.WithTelemetrySDK(),
		resource.WithAttributes(semconv.ServiceName(serviceName), semconv.ServiceInstanceID(instance)),
	)

	var shutdowns []func(context.Context) error
	if exp, err := otlptracegrpc.New(ctx); err == nil {
		tp := sdktrace.NewTracerProvider(sdktrace.WithBatcher(exp), sdktrace.WithResource(res))
		otel.SetTracerProvider(tp)
		shutdowns = append(shutdowns, tp.Shutdown)
	}
	if exp, err := otlpmetricgrpc.New(ctx); err == nil {
		mp := sdkmetric.NewMeterProvider(sdkmetric.WithReader(sdkmetric.NewPeriodicReader(exp)), sdkmetric.WithResource(res))
		otel.SetMeterProvider(mp)
		shutdowns = append(shutdowns, mp.Shutdown)
	}
	handlers := []slog.Handler{withTraceIDs{stdout}}
	if exp, err := otlploggrpc.New(ctx); err == nil {
		lp := sdklog.NewLoggerProvider(sdklog.WithProcessor(sdklog.NewBatchProcessor(exp)), sdklog.WithResource(res))
		global.SetLoggerProvider(lp)
		shutdowns = append(shutdowns, lp.Shutdown)
		handlers = append(handlers, otelslog.NewHandler(serviceName, otelslog.WithLoggerProvider(lp)))
	}

	log := slog.New(fanout(handlers)).With("service", serviceName)
	return log, func(ctx context.Context) error {
		var errs []error
		for _, s := range shutdowns {
			errs = append(errs, s(ctx))
		}
		return errors.Join(errs...)
	}
}

// withTraceIDs acrescenta trace_id/span_id no log do stdout (no Loki o bridge já faz isso).
type withTraceIDs struct{ slog.Handler }

func (h withTraceIDs) Handle(ctx context.Context, r slog.Record) error {
	if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
		r.AddAttrs(slog.String("trace_id", sc.TraceID().String()), slog.String("span_id", sc.SpanID().String()))
	}
	return h.Handler.Handle(ctx, r)
}

func (h withTraceIDs) WithAttrs(a []slog.Attr) slog.Handler {
	return withTraceIDs{h.Handler.WithAttrs(a)}
}
func (h withTraceIDs) WithGroup(n string) slog.Handler { return withTraceIDs{h.Handler.WithGroup(n)} }

// fanout manda cada log para stdout (JSON) e para o OpenTelemetry (Loki).
type fanout []slog.Handler

func (f fanout) Enabled(ctx context.Context, l slog.Level) bool {
	for _, h := range f {
		if h.Enabled(ctx, l) {
			return true
		}
	}
	return false
}

func (f fanout) Handle(ctx context.Context, r slog.Record) error {
	var errs []error
	for _, h := range f {
		if h.Enabled(ctx, r.Level) {
			errs = append(errs, h.Handle(ctx, r.Clone()))
		}
	}
	return errors.Join(errs...)
}

func (f fanout) WithAttrs(a []slog.Attr) slog.Handler {
	out := make(fanout, len(f))
	for i, h := range f {
		out[i] = h.WithAttrs(a)
	}
	return out
}

func (f fanout) WithGroup(n string) slog.Handler {
	out := make(fanout, len(f))
	for i, h := range f {
		out[i] = h.WithGroup(n)
	}
	return out
}
