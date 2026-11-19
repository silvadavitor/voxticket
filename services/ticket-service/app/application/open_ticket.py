"""Caso de uso: abrir chamado a partir de ``TicketRequested``."""
from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Any

from app.application.ports import UnitOfWorkFactory
from app.domain.events import IntegrationEvent, TicketEvents
from app.domain.exceptions import TicketRejectedError
from app.domain.policy import TicketOpeningPolicy
from app.domain.ticket import Ticket


@dataclass(frozen=True)
class OpenTicketCommand:
    message_id: str
    request_id: str
    tenant_id: str
    category: str
    priority: str | None = None
    transcript_key: str | None = None
    traceparent: str | None = None

    @classmethod
    def from_envelope(cls, envelope: dict[str, Any], traceparent: str | None = None) -> "OpenTicketCommand":
        payload = envelope["payload"]
        return cls(
            message_id=envelope["messageId"],
            request_id=payload["requestId"],
            tenant_id=payload["tenantId"],
            category=payload["category"],
            priority=payload.get("priority"),
            transcript_key=payload.get("transcriptKey"),
            traceparent=traceparent,
        )


class OpenTicketOutcome(str, Enum):
    OPENED = "opened"
    ALREADY_OPEN = "already_open"
    REJECTED = "rejected"
    DUPLICATE_MESSAGE = "duplicate_message"


@dataclass(frozen=True)
class OpenTicketResult:
    outcome: OpenTicketOutcome
    ticket_id: str | None = None
    reason: str | None = None


class OpenTicketUseCase:
    """Idempotente por ``messageId`` (processed_messages) e por ``requestId`` (UNIQUE).

    ``processed_messages`` + ticket + outbox são gravados na mesma transação.
    """

    def __init__(self, uow_factory: UnitOfWorkFactory, policy: TicketOpeningPolicy) -> None:
        self._uow_factory = uow_factory
        self._policy = policy

    async def execute(self, command: OpenTicketCommand) -> OpenTicketResult:
        async with self._uow_factory.create() as uow:
            if not await uow.processed_messages.register(command.message_id):
                return OpenTicketResult(OpenTicketOutcome.DUPLICATE_MESSAGE)

            result, event = await self._decide(uow, command)
            await uow.outbox.add(event, command.traceparent)
            return result

    async def _decide(self, uow, command: OpenTicketCommand) -> tuple[OpenTicketResult, IntegrationEvent]:
        existing = await uow.tickets.find_by_request_id(command.request_id)
        if existing is not None:
            return self._already_open(existing)

        try:
            self._policy.ensure_can_open(command.tenant_id, command.category)
        except TicketRejectedError as error:
            return (
                OpenTicketResult(OpenTicketOutcome.REJECTED, reason=error.reason),
                TicketEvents.rejected(command.request_id, error.reason),
            )

        candidate = Ticket.open(
            request_id=command.request_id,
            tenant_id=command.tenant_id,
            category=command.category,
            priority=command.priority,
            transcript_key=command.transcript_key,
        )
        persisted = await uow.tickets.add(candidate)
        if persisted.ticket_id != candidate.ticket_id:
            return self._already_open(persisted)
        return OpenTicketResult(OpenTicketOutcome.OPENED, ticket_id=persisted.ticket_id), TicketEvents.opened(persisted)

    @staticmethod
    def _already_open(ticket: Ticket) -> tuple[OpenTicketResult, IntegrationEvent]:
        # Republica TicketOpened com o mesmo ticketId: o orquestrador pode ter reenviado o pedido.
        return OpenTicketResult(OpenTicketOutcome.ALREADY_OPEN, ticket_id=ticket.ticket_id), TicketEvents.opened(ticket)
