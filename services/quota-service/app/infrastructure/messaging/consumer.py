"""Consumidor de ``AudioReceived``, ``CreditReleaseRequested`` e ``TicketOpened``."""
from __future__ import annotations

import asyncio
import logging
from typing import Any

from aio_pika.abc import AbstractIncomingMessage, AbstractRobustConnection
from opentelemetry import propagate, trace
from opentelemetry.trace import SpanKind, Status, StatusCode

from app.application.process_quota import ProcessQuotaCommand, ProcessQuotaUseCase
from app.infrastructure.messaging.broker_worker import MAX_BACKOFF_SECONDS, BrokerWorker
from app.infrastructure.messaging.contract_validator import ContractValidator, InvalidEnvelope
from app.infrastructure.observability.logging import message_log_context

logger = logging.getLogger(__name__)
tracer = trace.get_tracer(__name__)


class QuotaConsumer(BrokerWorker):
    """ACK só depois do COMMIT. Payload inválido → nack (DLQ após 3 entregas, pela fila quorum).
    Erro de infraestrutura → retry com backoff, sem mandar para a DLQ."""

    name = "quota-consumer"

    def __init__(
        self,
        broker_url: str,
        queue_name: str,
        validator: ContractValidator,
        use_case: ProcessQuotaUseCase,
    ) -> None:
        super().__init__(broker_url)
        self._queue_name = queue_name
        self._validator = validator
        self._use_case = use_case

    async def on_connected(self, connection: AbstractRobustConnection) -> None:
        channel = await connection.channel()
        await channel.set_qos(prefetch_count=1)
        queue = await channel.get_queue(self._queue_name, ensure=True)
        await queue.consume(self.handle, no_ack=False)
        closed = asyncio.ensure_future(channel.closed())
        stop = asyncio.ensure_future(self.wait_stop())
        try:
            await asyncio.wait({closed, stop}, return_when=asyncio.FIRST_COMPLETED)
        finally:
            closed.cancel()
            stop.cancel()
        if not self.stopping:
            raise ConnectionError("consumer channel closed")

    async def handle(self, message: AbstractIncomingMessage) -> None:
        try:
            envelope = self._validator.validate(message.body)
        except InvalidEnvelope as error:
            logger.warning("invalid message rejected (goes to DLQ after delivery limit): %s", error)
            await message.nack(requeue=True)
            return

        parent = propagate.extract(_text_headers(message.headers))
        with tracer.start_as_current_span("quota.consume", context=parent, kind=SpanKind.CONSUMER) as span, \
                message_log_context(envelope["correlationId"], envelope["messageId"], envelope["type"]):
            _annotate(span, envelope)
            carrier: dict[str, str] = {}
            propagate.inject(carrier)
            command = ProcessQuotaCommand.from_envelope(envelope, carrier.get("traceparent"))
            await self._process_with_retry(command, span)
            await message.ack()

    async def _process_with_retry(self, command: ProcessQuotaCommand, span: Any) -> None:
        attempt = 0
        while True:
            try:
                result = await self._use_case.execute(command)
                logger.info("quota event processed: %s", result.outcome.value)
                return
            except asyncio.CancelledError:
                raise
            except Exception as error:
                span.record_exception(error)
                span.set_status(Status(StatusCode.ERROR, str(error)))
                delay = min(2**attempt, MAX_BACKOFF_SECONDS)
                logger.exception("infrastructure error processing message; retrying in %ss", delay)
                await self.sleep(delay)
                if self.stopping:
                    raise
                attempt += 1


def _text_headers(headers: dict[str, Any] | None) -> dict[str, str]:
    result: dict[str, str] = {}
    for key, value in (headers or {}).items():
        result[key] = value.decode() if isinstance(value, bytes) else str(value)
    return result


def _annotate(span: Any, envelope: dict[str, Any]) -> None:
    span.set_attribute("messaging.message.id", envelope["messageId"])
    span.set_attribute("messaging.message.conversation_id", envelope["correlationId"])
    span.set_attribute("app.event_type", envelope["type"])
    tenant_id = envelope.get("payload", {}).get("tenantId")
    if tenant_id:
        span.set_attribute("app.tenant_id", tenant_id)
