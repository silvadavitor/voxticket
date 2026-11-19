"""Eventos de integração publicados pelo ticket-service (envelope dos contratos)."""
from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

from app.domain.ticket import Ticket


@dataclass(frozen=True)
class IntegrationEvent:
    type: str
    correlation_id: str
    payload: dict[str, Any]
    version: int = 1
    message_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    occurred_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))

    def to_envelope(self) -> dict[str, Any]:
        return {
            "messageId": self.message_id,
            "correlationId": self.correlation_id,
            "type": self.type,
            "version": self.version,
            "occurredAt": self.occurred_at.isoformat().replace("+00:00", "Z"),
            "payload": self.payload,
        }


class TicketEvents:
    """Fábrica dos eventos publicados."""

    @staticmethod
    def opened(ticket: Ticket) -> IntegrationEvent:
        payload: dict[str, Any] = {
            "requestId": ticket.request_id,
            "tenantId": ticket.tenant_id,
            "ticketId": ticket.ticket_id,
            "category": ticket.category,
        }
        if ticket.priority:
            payload["priority"] = ticket.priority
        return IntegrationEvent("TicketOpened", ticket.request_id, payload)

    @staticmethod
    def rejected(request_id: str, reason: str) -> IntegrationEvent:
        return IntegrationEvent("TicketRejected", request_id, {"requestId": request_id, "reason": reason})
