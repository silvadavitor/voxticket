"""OpenTelemetry: traces e métricas via OTLP, configurados só por variáveis padrão OTEL_*.

Propagação pelas mensagens: o traceparent atual é gravado na coluna outbox.traceparent no mesmo
INSERT; o relay abre um span PRODUCER filho dele e injeta o header no AMQP. O consumidor extrai o
header e abre um span CONSUMER.
"""

from __future__ import annotations

import logging
import os
from typing import Any, Callable, Iterable

from opentelemetry import metrics, propagate, trace
from opentelemetry.context import Context

log = logging.getLogger("transcription_worker.infra.telemetry")

_enabled = False


def setup_telemetry(service: str) -> None:
    global _enabled
    endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "").strip()
    if not endpoint or os.environ.get("OTEL_SDK_DISABLED", "").lower() == "true":
        log.info("opentelemetry disabled (OTEL_EXPORTER_OTLP_ENDPOINT vazio)")
        return
    try:
        from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
        from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
        from opentelemetry.sdk.metrics import MeterProvider
        from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
        from opentelemetry.sdk.resources import SERVICE_NAME, Resource
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor

        # OTEL_SERVICE_NAME e OTEL_RESOURCE_ATTRIBUTES são lidos por Resource.create
        resource = Resource.create({SERVICE_NAME: os.environ.get("OTEL_SERVICE_NAME", service)})
        insecure = endpoint.startswith("http://")
        tp = TracerProvider(resource=resource)
        tp.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(insecure=insecure)))
        trace.set_tracer_provider(tp)
        reader = PeriodicExportingMetricReader(OTLPMetricExporter(insecure=insecure), export_interval_millis=10_000)
        metrics.set_meter_provider(MeterProvider(resource=resource, metric_readers=[reader]))
        _enabled = True
        log.info("opentelemetry enabled", extra={"otlp_endpoint": endpoint})
    except Exception as exc:  # telemetria nunca derruba o serviço
        log.warning("opentelemetry setup failed: %s", exc)


def shutdown_telemetry() -> None:
    if not _enabled:
        return
    for provider in (trace.get_tracer_provider(), metrics.get_meter_provider()):
        try:
            provider.shutdown()  # type: ignore[attr-defined]
        except Exception:
            pass


def tracer() -> trace.Tracer:
    return trace.get_tracer("voxticket")


def meter() -> metrics.Meter:
    return metrics.get_meter("voxticket")


def current_traceparent() -> str | None:
    carrier: dict[str, str] = {}
    propagate.inject(carrier)
    return carrier.get("traceparent")


def context_from_headers(headers: dict[str, Any] | None) -> Context:
    carrier = {k: (v.decode() if isinstance(v, bytes) else str(v)) for k, v in (headers or {}).items()}
    return propagate.extract(carrier)


def inject_headers(headers: dict[str, Any]) -> dict[str, Any]:
    propagate.inject(headers)
    return headers


def message_attributes(message_id: str, correlation_id: str, event_type: str, tenant_id: str | None = None) -> dict:
    attrs = {
        "messaging.system": "rabbitmq",
        "messaging.message.id": message_id,
        "messaging.message.conversation_id": correlation_id,
        "app.event_type": event_type,
    }
    if tenant_id:
        attrs["app.tenant_id"] = tenant_id
    return attrs


def observable_gauge(name: str, description: str, read: Callable[[], int | None]) -> None:
    def _cb(_options: Any) -> Iterable[metrics.Observation]:
        value = read()
        return [] if value is None else [metrics.Observation(value)]

    meter().create_observable_gauge(name, callbacks=[_cb], description=description)
