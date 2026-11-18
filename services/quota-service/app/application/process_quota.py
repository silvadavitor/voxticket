"""Casos de uso de cota: reservar, liberar e consumir créditos."""
from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Any

from app.application.ports import UnitOfWork, UnitOfWorkFactory
from app.domain.events import IntegrationEvent, QuotaEvents
from app.domain.reservation import Reservation


@dataclass(frozen=True)
class ProcessQuotaCommand:
    message_id: str
    event_type: str
    request_id: str
    tenant_id: str
    traceparent: str | None = None

    @classmethod
    def from_envelope(cls, envelope: dict[str, Any], traceparent: str | None = None) -> "ProcessQuotaCommand":
        payload = envelope["payload"]
        return cls(
            message_id=envelope["messageId"],
            event_type=envelope["type"],
            request_id=payload["requestId"],
            tenant_id=payload["tenantId"],
            traceparent=traceparent,
        )


class QuotaOutcome(str, Enum):
    RESERVED = "reserved"
    ALREADY_RESERVED = "already_reserved"
    REJECTED = "rejected"
    RELEASED = "released"
    RELEASE_IGNORED = "release_ignored"
    CONSUMED = "consumed"
    CONSUME_IGNORED = "consume_ignored"
    DUPLICATE_MESSAGE = "duplicate_message"


@dataclass(frozen=True)
class ProcessQuotaResult:
    outcome: QuotaOutcome
    reservation_id: str | None = None
    reason: str | None = None


class ProcessQuotaUseCase:
    """Idempotente por ``messageId`` (processed_messages) e por ``requestId`` (PK).

    ``processed_messages`` + atualização de cota/reserva + outbox são gravados na mesma transação.
    """

    def __init__(self, uow_factory: UnitOfWorkFactory) -> None:
        self._uow_factory = uow_factory

    async def execute(self, command: ProcessQuotaCommand) -> ProcessQuotaResult:
        async with self._uow_factory.create() as uow:
            if not await uow.processed_messages.register(command.message_id):
                return ProcessQuotaResult(QuotaOutcome.DUPLICATE_MESSAGE)

            result, event = await self._dispatch(uow, command)
            if event is not None:
                await uow.outbox.add(event, command.traceparent)
            return result

    async def _dispatch(
        self, uow: UnitOfWork, command: ProcessQuotaCommand
    ) -> tuple[ProcessQuotaResult, IntegrationEvent | None]:
        handlers = {
            "AudioReceived": self._reserve,
            "CreditReleaseRequested": self._release,
            "TicketOpened": self._consume,
        }
        handler = handlers.get(command.event_type)
        if handler is None:
            raise ValueError(f"unsupported event type: {command.event_type}")
        return await handler(uow, command)

    async def _reserve(
        self, uow: UnitOfWork, command: ProcessQuotaCommand
    ) -> tuple[ProcessQuotaResult, IntegrationEvent]:
        existing = await uow.reservations.find_by_request_id(command.request_id)
        if existing is not None:
            return self._already_reserved(existing)

        if not await uow.quotas.try_reserve(command.tenant_id):
            await uow.quotas.ensure_tenant_exists(command.tenant_id)
            reason = "quota unavailable"
            return (
                ProcessQuotaResult(QuotaOutcome.REJECTED, reason=reason),
                QuotaEvents.rejected(command.request_id, command.tenant_id, reason),
            )

        candidate = Reservation.reserve(request_id=command.request_id, tenant_id=command.tenant_id)
        persisted = await uow.reservations.add(candidate)
        if persisted.reservation_id != candidate.reservation_id:
            return self._already_reserved(persisted)
        return (
            ProcessQuotaResult(QuotaOutcome.RESERVED, reservation_id=persisted.reservation_id),
            QuotaEvents.reserved(persisted),
        )

    async def _release(
        self, uow: UnitOfWork, command: ProcessQuotaCommand
    ) -> tuple[ProcessQuotaResult, None]:
        released = await uow.reservations.mark_released(command.request_id, command.tenant_id)
        if released:
            await uow.quotas.release(command.tenant_id)
            return ProcessQuotaResult(QuotaOutcome.RELEASED), None
        return ProcessQuotaResult(QuotaOutcome.RELEASE_IGNORED), None

    async def _consume(
        self, uow: UnitOfWork, command: ProcessQuotaCommand
    ) -> tuple[ProcessQuotaResult, None]:
        consumed = await uow.reservations.mark_consumed(command.request_id, command.tenant_id)
        outcome = QuotaOutcome.CONSUMED if consumed else QuotaOutcome.CONSUME_IGNORED
        return ProcessQuotaResult(outcome), None

    @staticmethod
    def _already_reserved(reservation: Reservation) -> tuple[ProcessQuotaResult, IntegrationEvent]:
        # Republica CreditReserved com o mesmo reservationId: o orquestrador pode ter reenviado o pedido.
        return (
            ProcessQuotaResult(QuotaOutcome.ALREADY_RESERVED, reservation_id=reservation.reservation_id),
            QuotaEvents.reserved(reservation),
        )
