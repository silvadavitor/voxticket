from __future__ import annotations

import logging
from typing import Awaitable, Callable

from aio_pika.abc import AbstractIncomingMessage
from opentelemetry import trace

from . import telemetry
from .envelope import Envelope, SchemaValidator
from .errors import InvalidMessage, is_infra_error
from .logs import log_context
from .retry import retry_infra

log = logging.getLogger("transcription_worker.infra.consumer")

Handler = Callable[[Envelope], Awaitable[None]]


class Consumer:
    def __init__(self, validator: SchemaValidator, handlers: dict[str, Handler]) -> None:
        self.validator = validator
        self.handlers = handlers

    async def on_message(self, message: AbstractIncomingMessage) -> None:
        delivery_count = (message.headers or {}).get("x-delivery-count", 0)
        try:
            envelope = self.validator.parse(message.body)
            handler = self.handlers.get(envelope.type)
            if handler is None:
                raise InvalidMessage(f"nenhum handler para {envelope.type}")
        except InvalidMessage as exc:
            with log_context(messageId=message.message_id, type=message.type, correlationId=message.correlation_id):
                log.error(
                    "invalid message, nack (goes to DLQ after delivery limit): %s",
                    exc,
                    extra={"delivery_count": delivery_count},
                )
            await self._safe(message.nack(requeue=True), "nack")
            return

        tenant = envelope.payload.get("tenantId")
        parent = telemetry.context_from_headers(message.headers)
        with log_context(
            correlationId=envelope.correlation_id, messageId=envelope.message_id, type=envelope.type, tenantId=tenant
        ):
            with telemetry.tracer().start_as_current_span(
                f"{envelope.type} process",
                context=parent,
                kind=trace.SpanKind.CONSUMER,
                attributes=telemetry.message_attributes(
                    envelope.message_id, envelope.correlation_id, envelope.type, tenant
                ),
            ) as span:
                log.info("received", extra={"delivery_count": delivery_count, "redelivered": message.redelivered})
                try:
                    await retry_infra(
                        lambda: handler(envelope),
                        f"handle {envelope.type}",
                        should_continue=lambda: _channel_open(message),
                    )
                except Exception as exc:
                    span.record_exception(exc)
                    span.set_status(trace.Status(trace.StatusCode.ERROR))
                    if is_infra_error(exc):
                        log.warning("channel closed while retrying; message will be redelivered")
                        return
                    log.exception("handler failed, nack", extra={"delivery_count": delivery_count})
                    await self._safe(message.nack(requeue=True), "nack")
                    return
                await self._safe(message.ack(), "ack")

    @staticmethod
    async def _safe(op: Awaitable[None], what: str) -> None:
        try:
            await op
        except Exception as exc:  # canal fechou: a mensagem volta para a fila e o R1 cuida da duplicata
            log.warning("%s failed (message will be redelivered): %s", what, exc)


def _channel_open(message: AbstractIncomingMessage) -> bool:
    try:
        return not message.channel.is_closed
    except Exception:
        return False
